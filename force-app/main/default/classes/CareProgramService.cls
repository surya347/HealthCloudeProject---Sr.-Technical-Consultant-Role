/**
 * Creates the Diabetes Management care program and enrols every patient with active diabetes.
 * Safe to run repeatedly: patients already enrolled are skipped.
 */
public with sharing class CareProgramService {

    public static final String PROGRAM_NAME = 'Diabetes Management Program';

    public static Id getOrCreateProgram() {
        List<CareProgram> existing = [SELECT Id FROM CareProgram WHERE Name = :PROGRAM_NAME LIMIT 1];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }
        CareProgram program = new CareProgram(
            Name = PROGRAM_NAME,
            Status = 'In Progress',
            StartDate = Date.today(),
            Description = 'Care management for adults with type 2 diabetes: HbA1c every 6 months, '
                + 'medication adherence and lifestyle coaching, outreach when a test is missed.'
        );
        insert program;
        return program.Id;
    }

    public static Integer enrollDiabeticPatients() {
        Id programId = getOrCreateProgram();

        Set<Id> diabeticPatientIds = new Set<Id>();
        for (HealthCondition hc : [
            SELECT PatientId FROM HealthCondition
            WHERE ConditionStatus = 'Active' AND ConditionCode.Name LIKE '%diabetes%'
        ]) {
            diabeticPatientIds.add(hc.PatientId);
        }

        Set<Id> alreadyEnrolled = new Set<Id>();
        for (CareProgramEnrollee e : [
            SELECT AccountId FROM CareProgramEnrollee
            WHERE CareProgramId = :programId AND AccountId IN :diabeticPatientIds
        ]) {
            alreadyEnrolled.add(e.AccountId);
        }

        List<CareProgramEnrollee> enrollees = new List<CareProgramEnrollee>();
        for (Account patient : [SELECT Id, Name FROM Account WHERE Id IN :diabeticPatientIds]) {
            if (alreadyEnrolled.contains(patient.Id)) {
                continue;
            }
            enrollees.add(new CareProgramEnrollee(
                Name = (patient.Name + ' - Diabetes Program').left(255),
                CareProgramId = programId,
                AccountId = patient.Id,
                Status = 'Active'
            ));
        }
        insert enrollees;
        return enrollees.size();
    }
}
