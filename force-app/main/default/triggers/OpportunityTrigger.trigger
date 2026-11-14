/**
 * OpportunityTrigger
 * ---------------------------------------------------------------------------------------------
 * WHAT: Keeps Account.Total_Won_Amount__c = SUM(Amount) of the Account's Closed Won Opportunities.
 *
 * BEST PRACTICE: one trigger per object, and NO logic here. The trigger only says WHEN to run;
 * OpportunityTriggerHandler decides WHAT to do. That keeps logic testable and reusable.
 *
 * WHY "after" events: we update a different object (Account), and after save the Opportunity
 * values (IsWon, Amount, AccountId) are final.
 * WHY delete + undelete too: deleting or restoring a won Opportunity also changes the total.
 */
trigger OpportunityTrigger on Opportunity (after insert, after update, after delete, after undelete) {
    OpportunityTriggerHandler.recalculateWonAmount(Trigger.new, Trigger.oldMap, Trigger.operationType);
}