/**
 * OpportunityTriggerHandlerTest
 * ---------------------------------------------------------------------------------------------
 * Proves Account.Total_Won_Amount__c stays correct in every case that can change it:
 * update to Closed Won, re-open, amount change, move to another Account, delete, undelete,
 * a change that should NOT touch the total, and a bulk load of 200 records.
 */
@IsTest
private class OpportunityTriggerHandlerTest {

    @TestSetup
    static void setup() {
        insert new List<Account>{ new Account(Name = 'Acme Test'), new Account(Name = 'Globex Test') };
    }

    // ---- small helpers to keep the tests readable ------------------------------------------
    static Id accountId(String name) {
        return [SELECT Id FROM Account WHERE Name = :name].Id;
    }

    static Decimal totalFor(String name) {
        return [SELECT Total_Won_Amount__c FROM Account WHERE Name = :name].Total_Won_Amount__c;
    }

    static Opportunity newOpp(String name, Id accId, String stage, Decimal amount) {
        return new Opportunity(Name = name, AccountId = accId, StageName = stage,
                               CloseDate = Date.today(), Amount = amount);
    }

    // ---- tests -------------------------------------------------------------------------------
    @IsTest
    static void updateToClosedWonSumsAllWonDeals() {
        Id acme = accountId('Acme Test');
        List<Opportunity> opps = new List<Opportunity>{
            newOpp('A', acme, 'Prospecting', 100),
            newOpp('B', acme, 'Prospecting', 250),
            newOpp('C', acme, 'Prospecting', 999)      // stays open: must NOT be counted
        };
        insert opps;

        Test.startTest();
        opps[0].StageName = 'Closed Won';
        opps[1].StageName = 'Closed Won';
        update opps;
        Test.stopTest();

        Assert.areEqual(350, totalFor('Acme Test'), 'Only the two won deals are summed');
    }

    @IsTest
    static void reopenAmountChangeAndReparentKeepBothAccountsRight() {
        Id acme = accountId('Acme Test');
        Id globex = accountId('Globex Test');
        Opportunity won = newOpp('Won deal', acme, 'Closed Won', 500);
        insert won;
        Assert.areEqual(500, totalFor('Acme Test'), 'Inserted as won');

        won.Amount = 650;                               // amount of a won deal changes
        update won;
        Assert.areEqual(650, totalFor('Acme Test'));

        won.AccountId = globex;                         // moved to another Account
        update won;
        Assert.areEqual(0, totalFor('Acme Test'), 'Old Account loses the amount');
        Assert.areEqual(650, totalFor('Globex Test'), 'New Account gains it');

        won.StageName = 'Prospecting';                  // re-opened
        update won;
        Assert.areEqual(0, totalFor('Globex Test'), 'No won deals left = 0, not a stale value');
    }

    @IsTest
    static void deleteAndUndeleteUpdateTheTotal() {
        Id acme = accountId('Acme Test');
        Opportunity won = newOpp('Won deal', acme, 'Closed Won', 300);
        insert won;

        delete won;
        Assert.areEqual(0, totalFor('Acme Test'), 'Deleting a won deal removes it');

        undelete won;
        Assert.areEqual(300, totalFor('Acme Test'), 'Restoring it adds it back');
    }

    @IsTest
    static void irrelevantChangeDoesNotUpdateAccount() {
        Id acme = accountId('Acme Test');
        Opportunity won = newOpp('Won deal', acme, 'Closed Won', 100);
        insert won;
        // Put a wrong value on the Account; an unrelated edit must not "fix" or touch it.
        update new Account(Id = acme, Total_Won_Amount__c = 1);

        Test.startTest();
        won.Description = 'Just a note';
        update won;
        Test.stopTest();

        Assert.areEqual(1, totalFor('Acme Test'), 'Handler skipped: description change cannot affect the sum');
    }

    @IsTest
    static void bulkInsertOf200WonDeals() {
        Id acme = accountId('Acme Test');
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(newOpp('Bulk ' + i, acme, 'Closed Won', 10));
        }

        Test.startTest();
        insert opps;                                    // one trigger run for 200 records
        Test.stopTest();

        Assert.areEqual(2000, totalFor('Acme Test'), 'Bulk-safe: 200 records in one run, no limit errors');
    }
}