/**
 * Apex controller for the careCoordinatorDashboard LWC.
 * Queries run WITH USER_MODE so object, field and sharing access of the coordinator is enforced.
 */
public with sharing class CareCoordinatorController {

    public class PatientRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String mrn;
        @AuraEnabled public Decimal riskScore;
        @AuraEnabled public Boolean careGapOpen;
        @AuraEnabled public Date lastHbA1cDate;
        @AuraEnabled public Decimal lastHbA1cValue;
        @AuraEnabled public Integer openTasks;
    }

    public class DashboardData {
        @AuraEnabled public Integer totalPatients = 0;
        @AuraEnabled public Integer highRiskPatients = 0;
        @AuraEnabled public Integer openCareGaps = 0;
        @AuraEnabled public Integer openTasks = 0;
        @AuraEnabled public List<PatientRow> patients = new List<PatientRow>();
    }

    public static final Integer HIGH_RISK_THRESHOLD = 70;

    @AuraEnabled(cacheable=true)
    public static DashboardData getDashboard() {
        try {
            List<Account> accounts = [
                SELECT Id, Name, Epic_MRN__c, Risk_Score__c, Care_Gap_Open__c, Last_HbA1c_Date__c, Last_HbA1c_Value__c
                FROM Account
                WHERE Epic_MRN__c != null AND Risk_Score__c != null
                WITH USER_MODE
                ORDER BY Risk_Score__c DESC NULLS LAST, Name
                LIMIT 200
            ];
            Set<Id> ids = new Map<Id, Account>(accounts).keySet();

            Map<Id, Integer> openTasksByPatient = new Map<Id, Integer>();
            for (AggregateResult ar : [
                SELECT WhatId patientId, COUNT(Id) total FROM Task
                WHERE WhatId IN :ids AND IsClosed = false
                WITH USER_MODE
                GROUP BY WhatId
            ]) {
                openTasksByPatient.put((Id) ar.get('patientId'), (Integer) ar.get('total'));
            }

            DashboardData data = new DashboardData();
            for (Account a : accounts) {
                PatientRow row = new PatientRow();
                row.id = a.Id;
                row.name = a.Name;
                row.mrn = a.Epic_MRN__c;
                row.riskScore = a.Risk_Score__c;
                row.careGapOpen = a.Care_Gap_Open__c;
                row.lastHbA1cDate = a.Last_HbA1c_Date__c;
                row.lastHbA1cValue = a.Last_HbA1c_Value__c;
                row.openTasks = openTasksByPatient.containsKey(a.Id) ? openTasksByPatient.get(a.Id) : 0;
                data.patients.add(row);

                data.totalPatients++;
                data.openTasks += row.openTasks;
                if (a.Risk_Score__c >= HIGH_RISK_THRESHOLD) {
                    data.highRiskPatients++;
                }
                if (a.Care_Gap_Open__c) {
                    data.openCareGaps++;
                }
            }
            return data;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void logOutreach(Id accountId, String notes) {
        try {
            Task call = new Task(
                WhatId = accountId,
                Subject = 'Outreach call',
                Status = 'Completed',
                Priority = 'Normal',
                ActivityDate = Date.today(),
                Description = notes
            );
            Database.insert(call, AccessLevel.USER_MODE);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}
