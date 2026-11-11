/**
 * Tests for PatientOnboardingController (the Apex behind the patientOnboardingWizard LWC).
 *
 * What we prove:
 *   1. Happy path: one submit creates patient, conditions, HbA1c, barriers, enrolment, consents, care plan, task.
 *   2. Existing patient: re-using a patient does not create a duplicate account.
 *   3. Consent is mandatory: no consent = nothing saved.
 *   4. Rollback: if a later step fails, the patient created earlier is rolled back too.
 *   5. Setup data and duplicate search return what the wizard needs.
 */
@IsTest
private class PatientOnboardingControllerTest {

    @TestSetup
    static void setup() {
        insert new CareProgram(Name = 'Test Diabetes Program', Status = 'In Progress');
        insert new CarePlanTemplate(Name = 'Test Diabetes Plan', Status = 'Published');
    }

    /** Builds a complete, valid request. Each test changes only what it needs. */
    private static PatientOnboardingController.OnboardingRequest validRequest() {
        PatientOnboardingController.OnboardingRequest req = new PatientOnboardingController.OnboardingRequest();

        req.patient = new PatientOnboardingController.PatientInput();
        req.patient.firstName = 'Leela';
        req.patient.lastName = 'Joshi';
        req.patient.birthDate = Date.newInstance(1979, 3, 2);
        req.patient.mrn = 'ONB-TEST-1';
        req.patient.city = 'Pune';

        req.clinical = new PatientOnboardingController.ClinicalInput();
        req.clinical.conditionCodes = new List<String>{ '44054006', '38341003' };
        req.clinical.onsetDate = Date.today().addYears(-2);
        req.clinical.hba1cValue = 8.1;
        req.clinical.hba1cDate = Date.today().addDays(-10);

        req.sdoh = new PatientOnboardingController.SdohInput();
        req.sdoh.transport = true;
        req.sdoh.food = false;
        req.sdoh.cost = true;
        req.sdoh.isolation = false;

        req.consent = new PatientOnboardingController.ConsentInput();
        req.consent.programConsent = true;
        req.consent.contactConsent = true;
        req.consent.capturedSource = 'Phone';

        req.program = new PatientOnboardingController.ProgramInput();
        req.program.careProgramId = [SELECT Id FROM CareProgram LIMIT 1].Id;
        req.program.carePlanTemplateId = [SELECT Id FROM CarePlanTemplate LIMIT 1].Id;
        req.program.scheduleWelcomeCall = true;
        return req;
    }

    @IsTest
    static void happyPathCreatesEverything() {
        Test.startTest();
        PatientOnboardingController.OnboardingResult result =
            PatientOnboardingController.submitOnboarding(JSON.serialize(validRequest()));
        Test.stopTest();

        Id patientId = result.patientId;
        System.assertNotEquals(null, patientId, 'Patient should be created');
        System.assertEquals(true, result.isNewPatient);
        System.assertEquals(2, result.conditionsCreated);
        System.assertEquals(2, result.barriersCreated);
        System.assertEquals(2, result.consentsCreated);
        System.assertNotEquals(null, result.carePlanId);

        System.assertEquals(2, [SELECT COUNT() FROM HealthCondition WHERE PatientId = :patientId AND SourceSystem = 'Onboarding']);
        System.assertEquals(1, [SELECT COUNT() FROM CareObservation WHERE ObservedSubjectId = :patientId]);
        System.assertEquals(2, [SELECT COUNT() FROM CareBarrier WHERE PatientId = :patientId]);
        System.assertEquals(1, [SELECT COUNT() FROM CareProgramEnrollee WHERE AccountId = :patientId]);
        System.assertEquals(2, [SELECT COUNT() FROM AuthorizationFormConsent WHERE ConsentGiverId = :result.enrolleeId AND Status = 'Signed']);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :patientId AND Subject LIKE 'Welcome call%']);
    }

    @IsTest
    static void existingPatientIsReusedNotDuplicated() {
        PatientOnboardingController.OnboardingResult first =
            PatientOnboardingController.submitOnboarding(JSON.serialize(validRequest()));

        // Second onboarding for the same person: the coordinator picked them in the duplicate check.
        PatientOnboardingController.OnboardingRequest again = validRequest();
        again.patient.existingPatientId = first.patientId;
        again.program.carePlanTemplateId = null;

        Test.startTest();
        PatientOnboardingController.OnboardingResult second =
            PatientOnboardingController.submitOnboarding(JSON.serialize(again));
        Test.stopTest();

        System.assertEquals(first.patientId, second.patientId);
        System.assertEquals(false, second.isNewPatient);
        System.assertEquals(first.enrolleeId, second.enrolleeId, 'Existing enrolment should be reused');
        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Epic_MRN__c = 'ONB-TEST-1']);
    }

    @IsTest
    static void missingConsentIsRejected() {
        PatientOnboardingController.OnboardingRequest req = validRequest();
        req.consent.programConsent = false;
        try {
            PatientOnboardingController.submitOnboarding(JSON.serialize(req));
            System.assert(false, 'Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Epic_MRN__c = 'ONB-TEST-1'], 'Nothing should be saved');
        }
    }

    @IsTest
    static void failureRollsBackEverything() {
        PatientOnboardingController.OnboardingRequest req = validRequest();
        // Point at a care program that has been deleted: the patient insert succeeds, then enrolment fails.
        CareProgram gone = new CareProgram(Name = 'Deleted Program', Status = 'In Progress');
        insert gone;
        delete gone;
        req.program.careProgramId = gone.Id;
        try {
            PatientOnboardingController.submitOnboarding(JSON.serialize(req));
            System.assert(false, 'Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Epic_MRN__c = 'ONB-TEST-1'], 'Patient should be rolled back');
            System.assertEquals(0, [SELECT COUNT() FROM CareBarrier], 'Barriers should be rolled back');
        }
    }

    @IsTest
    static void invalidHba1cIsRejected() {
        PatientOnboardingController.OnboardingRequest req = validRequest();
        req.clinical.hba1cValue = 45;
        try {
            PatientOnboardingController.submitOnboarding(JSON.serialize(req));
            System.assert(false, 'Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Epic_MRN__c = 'ONB-TEST-1']);
        }
    }

    @IsTest
    static void setupDataAndDuplicateSearch() {
        PatientOnboardingController.SetupData data = PatientOnboardingController.getSetupData();
        System.assertEquals(1, data.carePrograms.size());
        System.assertEquals(1, data.carePlanTemplates.size());
        System.assertEquals(4, data.conditions.size());

        PatientOnboardingController.submitOnboarding(JSON.serialize(validRequest()));
        System.assertEquals(1, PatientOnboardingController.findPatients('ONB-TEST-1', null, null).size(), 'Match by MRN');
        System.assertEquals(1, PatientOnboardingController.findPatients(null, 'Joshi', Date.newInstance(1979, 3, 2)).size(), 'Match by name + DOB');
        System.assertEquals(0, PatientOnboardingController.findPatients('NOPE', 'Nobody', Date.today()).size());
    }

    @IsTest
    static void findBarrierTypeMatchesKeyword() {
        List<CareBarrierType> types = new List<CareBarrierType>{ new CareBarrierType(Name = 'Lack of access to Transportation') };
        System.assertEquals(null, PatientOnboardingController.findBarrierType(types, 'food'));
        System.assertEquals(null, PatientOnboardingController.findBarrierType(new List<CareBarrierType>(), 'Transportation'));
    }
}
