/**
 * Tests for ProgramEnrollmentController (Apex behind the programEnrollmentWizard LWC).
 *   1. Context lists current enrolments and hides programs the patient is already in.
 *   2. Enrolling in a second program creates enrollee + consents + care plan + task.
 *   3. Double enrolment and missing consent are blocked, and nothing is saved.
 */
@IsTest
private class ProgramEnrollmentControllerTest {

    @TestSetup
    static void setup() {
        Account patient = new Account(
            RecordTypeId = PatientSupport.patientRecordTypeId(),
            FirstName = 'Ravi',
            LastName = 'Menon',
            PersonBirthdate = Date.newInstance(1975, 8, 14)
        );
        insert patient;
        CareProgram diabetes = new CareProgram(Name = 'Diabetes Program', Status = 'In Progress');
        CareProgram hypertension = new CareProgram(Name = 'Hypertension Program', Status = 'In Progress');
        insert new List<CareProgram>{ diabetes, hypertension };
        insert new CareProgramEnrollee(Name = 'Ravi Menon - Diabetes', AccountId = patient.Id,
            CareProgramId = diabetes.Id, Status = 'Active');
        insert new CarePlanTemplate(Name = 'Hypertension Plan', Status = 'Published');
    }

    private static Id patientId() {
        return [SELECT Id FROM Account WHERE LastName = 'Menon' LIMIT 1].Id;
    }
    private static Id programId(String name) {
        return [SELECT Id FROM CareProgram WHERE Name = :name LIMIT 1].Id;
    }

    private static ProgramEnrollmentController.EnrollmentRequest request(String programName) {
        ProgramEnrollmentController.EnrollmentRequest req = new ProgramEnrollmentController.EnrollmentRequest();
        req.patientId = patientId();
        req.careProgramId = programId(programName);
        req.carePlanTemplateId = [SELECT Id FROM CarePlanTemplate LIMIT 1].Id;
        req.programConsent = true;
        req.contactConsent = true;
        req.capturedSource = 'InPerson';
        req.scheduleWelcomeCall = true;
        return req;
    }

    @IsTest
    static void contextHidesProgramsAlreadyJoined() {
        ProgramEnrollmentController.EnrollmentContext ctx = ProgramEnrollmentController.getEnrollmentContext(patientId());
        System.assertEquals(true, ctx.isPatient);
        System.assertEquals(1, ctx.currentEnrollments.size());
        System.assertEquals('Diabetes Program', ctx.currentEnrollments[0].programName);
        System.assertEquals(1, ctx.availablePrograms.size(), 'Only the program not yet joined should be offered');
        System.assertEquals('Hypertension Program', ctx.availablePrograms[0].name);
        System.assertEquals(1, ctx.carePlanTemplates.size());
    }

    @IsTest
    static void enrolsInSecondProgram() {
        Test.startTest();
        ProgramEnrollmentController.EnrollmentResult result =
            ProgramEnrollmentController.enrollPatient(JSON.serialize(request('Hypertension Program')));
        Test.stopTest();

        Id pid = patientId();
        System.assertEquals('Hypertension Program', result.programName);
        System.assertEquals(2, result.consentsCreated);
        System.assertNotEquals(null, result.carePlanId);
        System.assertEquals(2, [SELECT COUNT() FROM CareProgramEnrollee WHERE AccountId = :pid]);
        System.assertEquals(2, [SELECT COUNT() FROM AuthorizationFormConsent WHERE ConsentGiverId = :result.enrolleeId]);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :pid AND Subject LIKE 'Welcome call%']);
    }

    @IsTest
    static void blocksDoubleEnrolment() {
        try {
            ProgramEnrollmentController.enrollPatient(JSON.serialize(request('Diabetes Program')));
            System.assert(false, 'Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('already enrolled'), e.getMessage());
        }
    }

    @IsTest
    static void blocksMissingConsent() {
        ProgramEnrollmentController.EnrollmentRequest req = request('Hypertension Program');
        req.programConsent = false;
        try {
            ProgramEnrollmentController.enrollPatient(JSON.serialize(req));
            System.assert(false, 'Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Id pid = patientId();
            System.assertEquals(1, [SELECT COUNT() FROM CareProgramEnrollee WHERE AccountId = :pid], 'Nothing saved');
        }
    }
}
