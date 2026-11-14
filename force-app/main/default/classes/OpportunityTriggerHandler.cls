/**
 * OpportunityTriggerHandler
 * ---------------------------------------------------------------------------------------------
 * Recalculates Account.Total_Won_Amount__c whenever a change can affect it.
 *
 * Simple idea in 3 steps:
 *   1. Find ONLY the Accounts whose total can change (skip edits like a new Description).
 *   2. Ask the database for the new totals with ONE aggregate query: SUM(Amount) GROUP BY Account.
 *   3. Save all those Accounts with ONE update.
 *
 * Example: Acme has won deals of 100 and 250. A third deal of 50 moves to Closed Won
 *          -> Acme.Total_Won_Amount__c becomes 400. If the 250 deal is re-opened -> 150.
 *
 * Best practices used:
 *   - Bulkified: works the same for 1 or 200 records (no SOQL / DML inside loops).
 *   - Recalculate from the source (SUM) instead of adding/subtracting, so the total never drifts.
 *   - IsWon instead of StageName = 'Closed Won' (still works if stages are renamed).
 *   - Handles re-parenting (both old and new Account), delete, undelete, and "no won deals" = 0.
 *   - "without sharing" ON PURPOSE: the total must include ALL won deals, even ones the current
 *     user cannot see. Otherwise the stored total would depend on who last edited a deal.
 *     Kept small and documented, as system-mode code should be.
 */
public without sharing class OpportunityTriggerHandler {

    public static void recalculateWonAmount(List<Opportunity> newList,
                                            Map<Id, Opportunity> oldMap,
                                            System.TriggerOperation operation) {

        // ---- Step 1: collect the Accounts that need a new total --------------------------
        Set<Id> accountIds = new Set<Id>();

        if (operation == System.TriggerOperation.AFTER_DELETE) {
            // Deleted records only exist in oldMap. Only a deleted WON deal changes a total.
            for (Opportunity oldOpp : oldMap.values()) {
                if (oldOpp.IsWon && oldOpp.AccountId != null) {
                    accountIds.add(oldOpp.AccountId);
                }
            }
        } else {
            for (Opportunity opp : newList) {
                Opportunity oldOpp = (oldMap == null) ? null : oldMap.get(opp.Id);

                // Was or is this deal won? If it is not won before or after, totals cannot change.
                Boolean wonBefore = oldOpp != null && oldOpp.IsWon;
                Boolean wonNow = opp.IsWon;
                if (!wonBefore && !wonNow) {
                    continue;
                }

                // Insert/undelete of a won deal, or a change that matters for the sum.
                Boolean changed = oldOpp == null
                    || wonBefore != wonNow                 // moved into or out of Closed Won
                    || opp.Amount != oldOpp.Amount         // amount of a won deal changed
                    || opp.AccountId != oldOpp.AccountId;  // deal moved to another Account
                if (!changed) {
                    continue;
                }

                if (opp.AccountId != null) {
                    accountIds.add(opp.AccountId);
                }
                if (oldOpp != null && oldOpp.AccountId != null) {
                    accountIds.add(oldOpp.AccountId);      // the old Account loses this amount
                }
            }
        }

        if (accountIds.isEmpty()) {
            return;                                        // nothing relevant changed: no SOQL, no DML
        }

        // ---- Step 2: one aggregate query for all Accounts --------------------------------
        Map<Id, Decimal> totalByAccount = new Map<Id, Decimal>();
        for (AggregateResult row : [
            SELECT AccountId accountId, SUM(Amount) total
            FROM Opportunity
            WHERE AccountId IN :accountIds AND IsWon = true
            GROUP BY AccountId
        ]) {
            totalByAccount.put((Id) row.get('accountId'), (Decimal) row.get('total'));
        }

        // ---- Step 3: one update; Accounts with no won deals get 0 ------------------------
        List<Account> accountsToUpdate = new List<Account>();
        for (Id accountId : accountIds) {
            Decimal total = totalByAccount.get(accountId);
            accountsToUpdate.add(new Account(
                Id = accountId,
                Total_Won_Amount__c = (total == null) ? 0 : total
            ));
        }
        update accountsToUpdate;
    }
}