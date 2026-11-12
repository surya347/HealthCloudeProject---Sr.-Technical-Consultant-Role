/**
 * Tests for Patient360Controller. The test patient is created through the real onboarding Apex,
 * so every section (conditions, HbA1c, barriers, program + consent, care plan, task) has data.
 */
@IsTest
private class Patient360ControllerTest {

    @TestSetup
    static void setup() {
        insert new CareProgram(Name = 'Test Diabetes Program', Status = 'In Progress');
        insert new CarePlanTemplate(Name = 'Test Diabetes Plan', Status = 'Published');

        PatientOnboardingController.OnboardingRequest r = new PatientOnboardingController.OnboardingRequest();
        r.patient = new PatientOnboardingController.PatientInput();
        r.patient.firstName = 'Leela';
        r.patient.lastName = 'Joshi';
        r.patient.birthDate = Date.newInstance(1979, 3, 2);
        r.patient.mrn = 'P360-TEST-1';
        r.patient.city = 'Pune';
        r.clinical = new PatientOnboardingController.ClinicalInput();
        r.clinical.conditionCodes = new List<String>{ '44054006', '38341003' };
        r.clinical.hba1cValue = 8.1;
        r.clinical.hba1cDate = Date.today().addDays(-10);
        r.sdoh = new PatientOnboardingController.SdohInput();
        r.sdoh.transport = true;
        r.consent = new PatientOnboardingController.ConsentInput();
        r.consent.programConsent = true;
        r.consent.contactConsent = true;
        r.consent.capturedSource = 'Phone';
        r.program = new PatientOnboardingController.ProgramInput();
        r.program.careProgramId = [SELECT Id FROM CareProgram LIMIT 1].Id;
        r.program.carePlanTemplateId = [SELECT Id FROM CarePlanTemplate LIMIT 1].Id;
        r.program.scheduleWelcomeCall = true;
        PatientOnboardingController.submitOnboarding(JSON.serialize(r));
    }

    @IsTest
    static void returnsEverySection() {
        Id patientId = [SELECT Id FROM Account WHERE Epic_MRN__c = 'P360-TEST-1'].Id;

        Test.startTest();
        Patient360Controller.Patient360 p = Patient360Controller.getPatient360(patientId);
        Test.stopTest();

        System.assertEquals('Leela Joshi', p.name);
        System.assertEquals('P360-TEST-1', p.mrn);
        System.assertNotEquals(null, p.age);
        System.assertEquals(2, p.conditions.size(), 'Two diagnoses');
        System.assertEquals(1, p.hba1cHistory.size(), 'One HbA1c result');
        System.assertEquals(8.1, p.lastHbA1cValue, 'Falls back to the observation when the job has not run');
        System.assertEquals(p.lastHbA1cDate.addDays(180), p.nextHbA1cDue);
        System.assertEquals(1, p.barriers.size());
        System.assertEquals(1, p.programs.size());
        System.assertEquals(true, p.programs[0].consentSigned, 'Program consent signed');
        System.assertEquals(true, p.programs[0].contactConsent, 'Phone/SMS consent signed');
        System.assertEquals(1, p.carePlans.size());
        System.assertEquals(1, p.openTasks.size(), 'Welcome call task');
        System.assertEquals('Not scored', p.riskLevel);
    }

    @IsTest
    static void unknownPatientThrows() {
        Account other = new Account(Name = 'Clinic Ltd');
        insert other;
        delete other;
        try {
            Patient360Controller.getPatient360(other.Id);
            System.assert(false, 'Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void helpersCalculateAgeAndRisk() {
        System.assertEquals(47, Patient360Controller.ageOn(Date.newInstance(1979, 3, 2), Date.newInstance(2026, 11, 12)));
        System.assertEquals(46, Patient360Controller.ageOn(Date.newInstance(1979, 12, 25), Date.newInstance(2026, 11, 12)));
        System.assertEquals(null, Patient360Controller.ageOn(null, Date.today()));
        System.assertEquals('High', Patient360Controller.riskLevel(70));
        System.assertEquals('Medium', Patient360Controller.riskLevel(40));
        System.assertEquals('Low', Patient360Controller.riskLevel(30));
        System.assertEquals('Not scored', Patient360Controller.riskLevel(null));
    }
}
