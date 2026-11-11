// Deletes the demo patients (their HealthCondition and CareObservation records cascade), tasks and logs,
// so you can re-run the demo from step 2. Does NOT touch the care program or code sets.
Set<Id> patientIds = new Map<Id, Account>([SELECT Id FROM Account WHERE Epic_MRN__c LIKE 'EPIC-%']).keySet();
delete [SELECT Id FROM Task WHERE WhatId IN :patientIds];
delete [SELECT Id FROM CareProgramEnrollee WHERE AccountId IN :patientIds];
delete [SELECT Id FROM Account WHERE Id IN :patientIds];
delete [SELECT Id FROM Integration_Log__c];
