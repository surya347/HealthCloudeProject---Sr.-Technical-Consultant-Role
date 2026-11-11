/**
 * Nightly care-gap check for diabetic patients.
 *
 * For every patient with an active diabetes HealthCondition it:
 *   1. finds the latest HbA1c CareObservation,
 *   2. flags a care gap when there is no HbA1c in the last GAP_DAYS days,
 *   3. calculates a simple 0-100 risk score,
 *   4. opens one outreach Task per open gap (and closes it again once the gap is closed).
 *
 * Run now:      Database.executeBatch(new CareGapBatch(), 200);
 * Schedule:     System.schedule('Nightly care gap check', '0 0 2 * * ?', new CareGapBatch());
 */
public with sharing class CareGapBatch implements Database.Batchable<SObject>, Schedulable {

    public static final Integer GAP_DAYS = 180;
    public static final String DIABETES_FILTER = '%diabetes%';
    public static final String HBA1C_NAME = 'Hemoglobin A1c';
    public static final String TASK_SUBJECT = 'Care gap: HbA1c test overdue';

    public Database.QueryLocator start(Database.BatchableContext bc) {
        String diabetesFilter = DIABETES_FILTER;
        return Database.getQueryLocator([
            SELECT Id, Name, Risk_Score__c, Care_Gap_Open__c
            FROM Account
            WHERE Id IN (
                SELECT PatientId FROM HealthCondition
                WHERE ConditionStatus = 'Active' AND ConditionCode.Name LIKE :diabetesFilter
            )
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Account> patients) {
        Set<Id> patientIds = new Map<Id, Account>(patients).keySet();

        // Other active conditions add to the risk score
        Map<Id, Integer> otherConditionCount = new Map<Id, Integer>();
        for (HealthCondition hc : [
            SELECT PatientId, ConditionCode.Name FROM HealthCondition
            WHERE PatientId IN :patientIds AND ConditionStatus = 'Active'
        ]) {
            if (hc.ConditionCode.Name != null && hc.ConditionCode.Name.containsIgnoreCase('diabetes')) {
                continue;
            }
            Integer current = otherConditionCount.containsKey(hc.PatientId) ? otherConditionCount.get(hc.PatientId) : 0;
            otherConditionCount.put(hc.PatientId, current + 1);
        }

        // Latest HbA1c per patient (query is ordered newest first, so the first one seen wins)
        String hba1cName = HBA1C_NAME;
        Map<Id, CareObservation> latestHbA1c = new Map<Id, CareObservation>();
        for (CareObservation co : Database.query(
            'SELECT ObservedSubjectId, EffectiveDateTime, ObservedValueNumerator FROM CareObservation ' +
            'WHERE ObservedSubjectId IN :patientIds AND Code.Name = :hba1cName ' +
            'ORDER BY EffectiveDateTime DESC'
        )) {
            if (!latestHbA1c.containsKey(co.ObservedSubjectId)) {
                latestHbA1c.put(co.ObservedSubjectId, co);
            }
        }

        // Existing open outreach tasks, so we never create duplicates
        Map<Id, Task> openTaskByPatient = new Map<Id, Task>();
        for (Task t : [
            SELECT Id, WhatId FROM Task
            WHERE WhatId IN :patientIds AND Subject = :TASK_SUBJECT AND IsClosed = false
        ]) {
            openTaskByPatient.put(t.WhatId, t);
        }

        Date cutoff = Date.today().addDays(-GAP_DAYS);
        List<Account> accountUpdates = new List<Account>();
        List<Task> tasksToInsert = new List<Task>();
        List<Task> tasksToClose = new List<Task>();

        for (Account patient : patients) {
            CareObservation last = latestHbA1c.get(patient.Id);
            Date lastDate = (last == null || last.EffectiveDateTime == null) ? null : last.EffectiveDateTime.dateGmt();
            Decimal lastValue = (last == null || last.ObservedValueNumerator == null)
                ? null : Decimal.valueOf(String.valueOf(last.ObservedValueNumerator)).setScale(1);
            Boolean gapOpen = (lastDate == null || lastDate < cutoff);

            Integer others = otherConditionCount.containsKey(patient.Id) ? otherConditionCount.get(patient.Id) : 0;
            Integer score = calculateRiskScore(gapOpen, lastValue, others);

            accountUpdates.add(new Account(
                Id = patient.Id,
                Care_Gap_Open__c = gapOpen,
                Risk_Score__c = score,
                Last_HbA1c_Date__c = lastDate,
                Last_HbA1c_Value__c = lastValue
            ));

            if (gapOpen && !openTaskByPatient.containsKey(patient.Id)) {
                tasksToInsert.add(new Task(
                    WhatId = patient.Id,
                    Subject = TASK_SUBJECT,
                    Priority = score >= 70 ? 'High' : 'Normal',
                    Status = 'Not Started',
                    ActivityDate = Date.today().addDays(score >= 70 ? 2 : 7),
                    Description = 'No HbA1c result in the last ' + GAP_DAYS + ' days'
                        + (lastDate == null ? ' (no result on file).' : ' (last test ' + lastDate.format() + ').')
                        + ' Call the patient and book a lab visit.'
                ));
            } else if (!gapOpen && openTaskByPatient.containsKey(patient.Id)) {
                tasksToClose.add(new Task(Id = openTaskByPatient.get(patient.Id).Id, Status = 'Completed'));
            }
        }

        update accountUpdates;
        insert tasksToInsert;
        update tasksToClose;
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'CareGapBatch finished: ' + bc.getJobId());
    }

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new CareGapBatch(), 200);
    }

    /**
     * Simple, explainable scoring (a real project would agree this with the clinical team):
     *   30 base for diabetes, +30 open care gap, +20 HbA1c >= 8% (+10 if >= 7%), +10 per other active condition.
     */
    @TestVisible
    private static Integer calculateRiskScore(Boolean gapOpen, Decimal lastHbA1c, Integer otherConditions) {
        Integer score = 30;
        if (gapOpen) {
            score += 30;
        }
        if (lastHbA1c != null && lastHbA1c >= 8) {
            score += 20;
        } else if (lastHbA1c != null && lastHbA1c >= 7) {
            score += 10;
        }
        score += 10 * otherConditions;
        return Math.min(score, 100);
    }
}
