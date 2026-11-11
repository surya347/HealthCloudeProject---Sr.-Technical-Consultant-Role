/**
 * ProgramEnrollmentController
 * ---------------------------------------------------------------------------------------------
 * Apex back end for the programEnrollmentWizard LWC, which sits on a PATIENT RECORD PAGE.
 * It enrols a patient who already exists in ANOTHER care program.
 *
 * Onboarding wizard vs this wizard (interview line):
 *   - patientOnboardingWizard  = brand-new patient: record + history + SDOH + consent + program.
 *   - programEnrollmentWizard  = existing patient: just program + consent + optional care plan.
 *
 * It reuses PatientOnboardingController's helpers (enrol, recordConsent, createCarePlan),
 * so enrolment and consent work exactly the same way in both wizards (one source of truth).
 *
 * Example LWC call:
 *   enrollPatient({ requestJson: JSON.stringify({ patientId: '001...', careProgramId: '0ZQ...',
 *       programConsent: true, contactConsent: false, capturedSource: 'Phone' }) })
 */
public with sharing class ProgramEnrollmentController {

    // ============================================================ DTOs

    /** What the component needs to draw itself for one patient. */
    public class EnrollmentContext {
        @AuraEnabled public Id patientId;
        @AuraEnabled public String patientName;
        @AuraEnabled public Boolean isPatient;                                  // false on business accounts
        @AuraEnabled public List<CurrentEnrollment> currentEnrollments = new List<CurrentEnrollment>();
        @AuraEnabled public List<ProgramOption> availablePrograms = new List<ProgramOption>();
        @AuraEnabled public List<PatientOnboardingController.Option> carePlanTemplates =
            new List<PatientOnboardingController.Option>();
    }

    /** A program the patient is already in. Example: { programName: 'Diabetes Management Program', status: 'Active' } */
    public class CurrentEnrollment {
        @AuraEnabled public Id enrolleeId;
        @AuraEnabled public String programName;
        @AuraEnabled public String status;
        @AuraEnabled public Date enrolledOn;
    }

    /** A program the patient can still join, shown as a selectable tile. */
    public class ProgramOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String description;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date endDate;
    }

    /** Mirrors the "form" object in programEnrollmentWizard.js. */
    public class EnrollmentRequest {
        public Id patientId;
        public Id careProgramId;
        public Id carePlanTemplateId;      // optional
        public Boolean programConsent;     // required
        public Boolean contactConsent;
        public String capturedSource;      // InPerson, Phone, Video, Email, Web
        public Boolean scheduleWelcomeCall;
    }

    public class EnrollmentResult {
        @AuraEnabled public Id enrolleeId;
        @AuraEnabled public String programName;
        @AuraEnabled public Id carePlanId;
        @AuraEnabled public Integer consentsCreated = 0;
    }

    // ============================================================ Read

    /**
     * Loads the patient's current enrolments and the programs they can still join.
     * Programs the patient is ALREADY in are left out, so the coordinator can't double-enrol.
     * cacheable=true -> used with @wire; the LWC calls refreshApex() after a successful enrolment.
     */
    @AuraEnabled(cacheable=true)
    public static EnrollmentContext getEnrollmentContext(Id patientId) {
        try {
            EnrollmentContext ctx = new EnrollmentContext();
            Account patient = [
                SELECT Id, Name, IsPersonAccount FROM Account WHERE Id = :patientId WITH USER_MODE LIMIT 1
            ];
            ctx.patientId = patient.Id;
            ctx.patientName = patient.Name;
            ctx.isPatient = patient.IsPersonAccount;

            Set<Id> enrolledProgramIds = new Set<Id>();
            for (CareProgramEnrollee e : [
                SELECT Id, Status, CreatedDate, CareProgramId, CareProgram.Name
                FROM CareProgramEnrollee
                WHERE AccountId = :patientId
                WITH USER_MODE
                ORDER BY CreatedDate DESC
            ]) {
                CurrentEnrollment c = new CurrentEnrollment();
                c.enrolleeId = e.Id;
                c.programName = e.CareProgram.Name;
                c.status = e.Status;
                c.enrolledOn = e.CreatedDate.date();
                ctx.currentEnrollments.add(c);
                enrolledProgramIds.add(e.CareProgramId);
            }

            for (CareProgram p : [
                SELECT Id, Name, Description, StartDate, EndDate
                FROM CareProgram
                WHERE Id NOT IN :enrolledProgramIds
                  AND Status != 'Completed' AND Status != 'Cancelled'
                WITH USER_MODE
                ORDER BY Name
                LIMIT 200
            ]) {
                ProgramOption o = new ProgramOption();
                o.id = p.Id;
                o.name = p.Name;
                o.description = p.Description;
                o.startDate = p.StartDate;
                o.endDate = p.EndDate;
                ctx.availablePrograms.add(o);
            }

            // Re-use the onboarding wizard's list of published care plan templates.
            ctx.carePlanTemplates = PatientOnboardingController.getSetupData().carePlanTemplates;
            return ctx;
        } catch (Exception e) {
            throw PatientOnboardingController.auraError('Could not load enrolment details: ' + e.getMessage());
        }
    }

    // ============================================================ Write

    /**
     * Enrols the patient in one more program, records consent, and optionally adds a care plan + task.
     * All in one transaction: if any part fails, nothing is saved.
     */
    @AuraEnabled
    public static EnrollmentResult enrollPatient(String requestJson) {
        EnrollmentRequest req;
        try {
            req = (EnrollmentRequest) JSON.deserialize(requestJson, EnrollmentRequest.class);
        } catch (Exception e) {
            throw PatientOnboardingController.auraError('The enrolment form could not be read. Please try again.');
        }
        validate(req);

        Savepoint sp = Database.setSavepoint();
        try {
            Account patient = [
                SELECT Id, Name, PersonContactId FROM Account WHERE Id = :req.patientId WITH USER_MODE LIMIT 1
            ];

            CareProgramEnrollee enrollee = PatientOnboardingController.enrol(patient, req.careProgramId);

            PatientOnboardingController.ConsentInput consent = new PatientOnboardingController.ConsentInput();
            consent.programConsent = req.programConsent;
            consent.contactConsent = req.contactConsent;
            consent.capturedSource = req.capturedSource;

            EnrollmentResult result = new EnrollmentResult();
            result.enrolleeId = enrollee.Id;
            result.programName = [SELECT Name FROM CareProgram WHERE Id = :req.careProgramId WITH USER_MODE].Name;
            result.consentsCreated = PatientOnboardingController.recordConsent(enrollee.Id, consent);

            if (req.carePlanTemplateId != null) {
                result.carePlanId = PatientOnboardingController.createCarePlan(patient, req.carePlanTemplateId);
            }
            if (req.scheduleWelcomeCall == true) {
                Database.insert(new Task(
                    WhatId = patient.Id,
                    Subject = ('Welcome call: ' + result.programName).left(255),
                    Status = 'Not Started',
                    Priority = 'Normal',
                    ActivityDate = Date.today().addDays(2),
                    Description = 'Explain the new program, goals and next appointments.'
                ), AccessLevel.USER_MODE);
            }
            return result;
        } catch (Exception e) {
            Database.rollback(sp);
            throw PatientOnboardingController.auraError('Enrolment was not saved: ' + e.getMessage());
        }
    }

    /** Server-side checks (the LWC checks the same things, but never trust the client alone). */
    @TestVisible
    private static void validate(EnrollmentRequest req) {
        if (req == null || req.patientId == null) {
            throw PatientOnboardingController.auraError('Open this from a patient record.');
        }
        if (req.careProgramId == null) {
            throw PatientOnboardingController.auraError('Choose a care program.');
        }
        if (req.programConsent != true) {
            throw PatientOnboardingController.auraError('Program consent is required before enrolment.');
        }
        // Block double enrolment (the onboarding wizard re-uses an existing enrolment; here it's an error,
        // because the coordinator explicitly asked to ADD a new program).
        Integer already = [
            SELECT COUNT() FROM CareProgramEnrollee
            WHERE AccountId = :req.patientId AND CareProgramId = :req.careProgramId
        ];
        if (already > 0) {
            throw PatientOnboardingController.auraError('This patient is already enrolled in that program.');
        }
    }
}
