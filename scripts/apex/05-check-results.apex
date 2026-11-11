// Quick check after steps 2-5
for (Account a : [SELECT Name, Epic_MRN__c, Risk_Score__c, Care_Gap_Open__c, Last_HbA1c_Date__c, Last_HbA1c_Value__c
                  FROM Account WHERE Epic_MRN__c != null ORDER BY Risk_Score__c DESC NULLS LAST]) {
    System.debug(LoggingLevel.ERROR, a.Epic_MRN__c + ' | ' + a.Name + ' | risk ' + a.Risk_Score__c
        + ' | gap ' + a.Care_Gap_Open__c + ' | last HbA1c ' + a.Last_HbA1c_Date__c + ' (' + a.Last_HbA1c_Value__c + '%)');
}
System.debug(LoggingLevel.ERROR, 'Conditions: ' + [SELECT COUNT() FROM HealthCondition WHERE SourceSystem = 'Epic']
    + ' | Observations: ' + [SELECT COUNT() FROM CareObservation WHERE Name LIKE 'EPIC-%']
    + ' | Open gap tasks: ' + [SELECT COUNT() FROM Task WHERE Subject = :CareGapBatch.TASK_SUBJECT AND IsClosed = false]);
