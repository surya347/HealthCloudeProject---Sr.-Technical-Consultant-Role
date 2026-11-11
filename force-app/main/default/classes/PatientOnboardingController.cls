/**
 * PatientOnboardingController
 * ---------------------------------------------------------------------------------------------
 * Apex back end for the patientOnboardingWizard LWC.
 *
 * The wizard collects everything needed to onboard a patient and enrol them in a care program:
 *   1. Patient details     -> Account (person account, Patient record type)
 *   2. Clinical history    -> HealthCondition + optional HbA1c CareObservation
 *   3. SDOH screening      -> CareBarrier (one per "yes" answer)
 *   4. Consent             -> AuthorizationFormConsent (Health Cloud's standard consent model)
 *   5. Program & care plan -> CareProgramEnrollee, optional Case + CarePlan from a template
 *   6. Review & submit     -> everything above is saved in ONE transaction
 *
 * Best practices used here:
 *   - "with sharing" + AccessLevel.USER_MODE: the coordinator's own permissions and sharing apply.
 *   - One Savepoint: if any step fails, NOTHING is saved (no half-onboarded patients).
 *   - Typed request/response classes (DTOs) instead of loose maps, so the contract with the LWC is clear.
 *   - Server-side validation even though the LWC validates too (never trust the client alone).
 *   - Bulk-safe DML: records are collected into lists and inserted once per object.
 *
 * Example call from the LWC (see patientOnboardingWizard.js):
 *   submitOnboarding({ requestJson: JSON.stringify(this.form) })
 *     .then(result => this.navigateToRecord(result.patientId));
 */
public with sharing class PatientOnboardingController {

    // ============================================================ Constants

    /** Name of the authorization form that holds the onboarding consent texts. */
    @TestVisible static final String CONSENT_FORM_NAME = 'Patient Onboarding Consents';
    @TestVisible static final String PROGRAM_CONSENT_TEXT = 'Care Program Participation Consent';
    @TestVisible static final String CONTACT_CONSENT_TEXT = 'Phone and SMS Contact Consent';

    /** The wording shown to the patient (same text as the wizard's consent box). */
    @TestVisible static final Map<String, String> CONSENT_WORDING = new Map<String, String>{
        PROGRAM_CONSENT_TEXT => 'I agree to join the care program. My care team may review my health information, '
            + 'contact me about tests and appointments, and share information with my doctors to coordinate my care. '
            + 'I can withdraw at any time.',
        CONTACT_CONSENT_TEXT => 'I agree that my care team may contact me by phone call and SMS about my care, '
            + 'appointments and test reminders.'
    };

    /**
     * Condition codes the wizard offers. Each entry: SNOMED code -> display name.
     * Example: '44054006' is SNOMED CT for "Type 2 diabetes mellitus".
     */
    @TestVisible static final Map<String, String> CONDITION_OPTIONS = new Map<String, String>{
        '44054006' => 'Type 2 diabetes mellitus',
        '38341003' => 'Hypertension',
        '13644009' => 'Hypercholesterolemia',
        '709044004' => 'Chronic kidney disease'
    };

    /**
     * SDOH screening questions -> keyword used to find the matching CareBarrierType in the org.
     * Example: answering "yes" to 'transport' looks for a barrier type whose name contains "Transportation".
     */
    @TestVisible static final Map<String, String> SDOH_KEYWORDS = new Map<String, String>{
        'transport' => 'Transportation',
        'food' => 'food',
        'cost' => 'Income',
        'isolation' => 'isolation'
    };
    @TestVisible static final Map<String, String> SDOH_BARRIER_NAMES = new Map<String, String>{
        'transport' => 'Lack of access to Transportation',
        'food' => 'Food insecurity',
        'cost' => 'Cannot afford medication',
        'isolation' => 'Lives alone / social isolation'
    };

    // ============================================================ Request / response DTOs

    /** Mirrors the "form" object built by the wizard. Every property name matches the JS side. */
    public class OnboardingRequest {
        public PatientInput patient;
        public ClinicalInput clinical;
        public SdohInput sdoh;
        public ConsentInput consent;
        public ProgramInput program;
    }

    public class PatientInput {
        public Id existingPatientId;   // set when the coordinator picked an existing patient (duplicate check)
        public String firstName;
        public String lastName;
        public Date birthDate;
        public String mrn;             // Epic medical record number, e.g. 'EPIC-100021'
        public String phone;
        public String email;
        public String city;
    }

    public class ClinicalInput {
        public List<String> conditionCodes;  // e.g. ['44054006', '38341003']
        public Date onsetDate;
        public Decimal hba1cValue;           // e.g. 7.4 (%)
        public Date hba1cDate;
    }

    public class SdohInput {
        public Boolean transport;
        public Boolean food;
        public Boolean cost;
        public Boolean isolation;
        public String notes;
    }

    public class ConsentInput {
        public Boolean programConsent;       // REQUIRED to enrol
        public Boolean contactConsent;       // optional: OK to contact by phone / SMS
        public String capturedSource;        // 'Phone', 'InPerson', 'Email', 'Web' ...
    }

    public class ProgramInput {
        public Id careProgramId;
        public Id carePlanTemplateId;        // optional: also create a care plan from this template
        public Boolean scheduleWelcomeCall;
    }

    /** What the wizard shows on its success screen. */
    public class OnboardingResult {
        @AuraEnabled public Id patientId;
        @AuraEnabled public String patientName;
        @AuraEnabled public Id enrolleeId;
        @AuraEnabled public Id carePlanId;
        @AuraEnabled public Integer conditionsCreated = 0;
        @AuraEnabled public Integer barriersCreated = 0;
        @AuraEnabled public Integer consentsCreated = 0;
        @AuraEnabled public Boolean isNewPatient;
    }

    /** Picklist-style option for comboboxes and checkbox groups: { label, value }. */
    public class Option {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        Option(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    /** Everything the wizard needs to render its choices, loaded once with @wire. */
    public class SetupData {
        @AuraEnabled public List<Option> carePrograms = new List<Option>();
        @AuraEnabled public List<Option> carePlanTemplates = new List<Option>();
        @AuraEnabled public List<Option> conditions = new List<Option>();
    }

    /** One possible duplicate returned by the "Check for existing patient" step. */
    public class PatientMatch {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String mrn;
        @AuraEnabled public Date birthDate;
        @AuraEnabled public String city;
    }

    // ============================================================ Read methods (cacheable)

    /**
     * Loads the active care programs, published care plan templates and condition options.
     * cacheable=true lets the LWC use @wire and Lightning Data Service caching.
     *
     * Example result:
     *   { carePrograms: [{label:'Diabetes Management Program', value:'0ZQ...'}], ... }
     */
    @AuraEnabled(cacheable=true)
    public static SetupData getSetupData() {
        try {
            SetupData data = new SetupData();
            for (CareProgram cp : [
                SELECT Id, Name FROM CareProgram
                WHERE Status != 'Completed' AND Status != 'Cancelled'
                WITH USER_MODE
                ORDER BY Name
                LIMIT 200
            ]) {
                data.carePrograms.add(new Option(cp.Name, cp.Id));
            }
            for (CarePlanTemplate t : [
                SELECT Id, Name FROM CarePlanTemplate
                WHERE Status = 'Published'
                WITH USER_MODE
                ORDER BY Name
                LIMIT 200
            ]) {
                data.carePlanTemplates.add(new Option(t.Name, t.Id));
            }
            for (String code : CONDITION_OPTIONS.keySet()) {
                data.conditions.add(new Option(CONDITION_OPTIONS.get(code) + ' (SNOMED ' + code + ')', code));
            }
            return data;
        } catch (Exception e) {
            throw auraError('Could not load onboarding options: ' + e.getMessage());
        }
    }

    /**
     * Duplicate check before creating a patient. Matches on MRN, OR on last name + date of birth.
     * Example: findPatients('EPIC-100001', null, null) returns Aarav Nair.
     */
    @AuraEnabled
    public static List<PatientMatch> findPatients(String mrn, String lastName, Date birthDate) {
        try {
            String mrnValue = String.isBlank(mrn) ? '__none__' : mrn.trim();
            String nameValue = String.isBlank(lastName) ? '__none__' : lastName.trim();
            List<PatientMatch> matches = new List<PatientMatch>();
            for (Account a : [
                SELECT Id, Name, Epic_MRN__c, PersonBirthdate, PersonMailingCity
                FROM Account
                WHERE IsPersonAccount = true
                  AND (Epic_MRN__c = :mrnValue OR (LastName = :nameValue AND PersonBirthdate = :birthDate))
                WITH USER_MODE
                LIMIT 10
            ]) {
                PatientMatch m = new PatientMatch();
                m.id = a.Id;
                m.name = a.Name;
                m.mrn = a.Epic_MRN__c;
                m.birthDate = a.PersonBirthdate;
                m.city = a.PersonMailingCity;
                matches.add(m);
            }
            return matches;
        } catch (Exception e) {
            throw auraError('Duplicate check failed: ' + e.getMessage());
        }
    }

    // ============================================================ Write method

    /**
     * Saves the whole onboarding in a single transaction.
     * The LWC sends the form as JSON; JSON.deserialize turns it into the typed OnboardingRequest.
     *
     * Example requestJson (shortened):
     *   {"patient":{"firstName":"Leela","lastName":"Joshi","birthDate":"1979-03-02","mrn":"EPIC-100021"},
     *    "clinical":{"conditionCodes":["44054006"],"hba1cValue":8.1,"hba1cDate":"2026-10-01"},
     *    "sdoh":{"transport":true},
     *    "consent":{"programConsent":true,"capturedSource":"Phone"},
     *    "program":{"careProgramId":"0ZQ...","scheduleWelcomeCall":true}}
     */
    @AuraEnabled
    public static OnboardingResult submitOnboarding(String requestJson) {
        OnboardingRequest req;
        try {
            req = (OnboardingRequest) JSON.deserialize(requestJson, OnboardingRequest.class);
        } catch (Exception e) {
            throw auraError('The onboarding form could not be read. Please try again.');
        }
        validate(req);

        // Savepoint = "undo point". If anything below fails we roll back to here,
        // so we never leave a patient created without their enrolment, consent, etc.
        Savepoint sp = Database.setSavepoint();
        try {
            OnboardingResult result = new OnboardingResult();

            Account patient = upsertPatient(req.patient, result);
            result.conditionsCreated = createClinicalHistory(patient.Id, req.clinical);
            result.barriersCreated = createBarriers(patient.Id, req.sdoh);

            CareProgramEnrollee enrollee = enrol(patient, req.program.careProgramId);
            result.enrolleeId = enrollee.Id;

            result.consentsCreated = recordConsent(enrollee.Id, req.consent);

            if (req.program.carePlanTemplateId != null) {
                result.carePlanId = createCarePlan(patient, req.program.carePlanTemplateId);
            }
            if (req.program.scheduleWelcomeCall == true) {
                insertUserMode(new List<SObject>{ new Task(
                    WhatId = patient.Id,
                    Subject = 'Welcome call: new program enrolment',
                    Status = 'Not Started',
                    Priority = 'Normal',
                    ActivityDate = Date.today().addDays(2),
                    Description = 'Introduce the care team, confirm contact preferences and next appointments.'
                ) });
            }
            return result;
        } catch (Exception e) {
            Database.rollback(sp);
            throw auraError('Onboarding was not saved: ' + e.getMessage());
        }
    }

    // ============================================================ Validation

    /** Server-side checks. These mirror the LWC's checks, so bad data can't get in through the API. */
    @TestVisible
    private static void validate(OnboardingRequest req) {
        List<String> errors = new List<String>();
        if (req == null || req.patient == null || req.program == null || req.consent == null) {
            throw auraError('The onboarding form is incomplete.');
        }
        if (req.patient.existingPatientId == null) {
            if (String.isBlank(req.patient.lastName)) {
                errors.add('Last name is required.');
            }
            if (req.patient.birthDate == null) {
                errors.add('Date of birth is required.');
            } else if (req.patient.birthDate > Date.today()) {
                errors.add('Date of birth cannot be in the future.');
            }
        }
        if (req.program.careProgramId == null) {
            errors.add('Choose a care program.');
        }
        // Consent first: a patient must agree before being enrolled.
        if (req.consent.programConsent != true) {
            errors.add('Program consent is required before enrolment.');
        }
        if (req.clinical != null && req.clinical.hba1cValue != null
                && (req.clinical.hba1cValue < 3 || req.clinical.hba1cValue > 20)) {
            errors.add('HbA1c must be between 3% and 20%.');
        }
        if (!errors.isEmpty()) {
            throw auraError(String.join(errors, ' '));
        }
    }

    // ============================================================ Steps

    /** Step 1: reuse the existing patient picked in the duplicate check, or create a new person account. */
    private static Account upsertPatient(PatientInput p, OnboardingResult result) {
        if (p.existingPatientId != null) {
            Account existing = [
                SELECT Id, Name, PersonContactId FROM Account
                WHERE Id = :p.existingPatientId WITH USER_MODE LIMIT 1
            ];
            result.patientId = existing.Id;
            result.patientName = existing.Name;
            result.isNewPatient = false;
            return existing;
        }
        Account a = new Account(
            RecordTypeId = PatientSupport.patientRecordTypeId(),
            FirstName = p.firstName,
            LastName = p.lastName,
            PersonBirthdate = p.birthDate,
            PersonMobilePhone = p.phone,
            PersonEmail = p.email,
            PersonMailingCity = p.city,
            Epic_MRN__c = String.isBlank(p.mrn) ? null : p.mrn.trim()
        );
        insertUserMode(new List<SObject>{ a });
        Account created = [SELECT Id, Name, PersonContactId FROM Account WHERE Id = :a.Id WITH USER_MODE];
        result.patientId = created.Id;
        result.patientName = created.Name;
        result.isNewPatient = true;
        return created;
    }

    /** Step 2: one HealthCondition per selected code, plus an optional HbA1c result. Returns conditions created. */
    private static Integer createClinicalHistory(Id patientId, ClinicalInput c) {
        if (c == null) {
            return 0;
        }
        List<SObject> records = new List<SObject>();
        Datetime onset = c.onsetDate == null ? null : Datetime.newInstanceGmt(c.onsetDate, Time.newInstance(0, 0, 0, 0));
        if (c.conditionCodes != null) {
            for (String code : c.conditionCodes) {
                if (!CONDITION_OPTIONS.containsKey(code)) {
                    continue; // ignore anything that isn't one of our known codes
                }
                records.add(new HealthCondition(
                    PatientId = patientId,
                    // CodeSetService finds or creates the SNOMED code record, e.g. 44054006
                    ConditionCodeId = CodeSetService.resolveFor(HealthCondition.ConditionCodeId, code, CONDITION_OPTIONS.get(code)),
                    ConditionStatus = 'Active',
                    OnsetStartDateTime = onset,
                    SourceSystem = 'Onboarding'
                ));
            }
        }
        Integer conditionCount = records.size();
        if (c.hba1cValue != null && c.hba1cDate != null) {
            records.add(new CareObservation(
                Name = 'ONB-A1C-' + String.valueOf(patientId).right(6) + '-' + String.valueOf(c.hba1cDate),
                ObservedSubjectId = patientId,
                CodeId = CodeSetService.resolveFor(CareObservation.CodeId, '4548-4', 'Hemoglobin A1c'), // LOINC HbA1c
                ObservationStatus = 'Final',
                EffectiveDateTime = Datetime.newInstanceGmt(c.hba1cDate, Time.newInstance(9, 0, 0, 0)),
                ObservedValueType = 'Quantity',
                ObservedValueNumerator = c.hba1cValue,
                ObservedValueUnitId = FhirIngestService.unitOfMeasureId('%') // Health Cloud requires a unit
            ));
        }
        insertUserMode(records);
        return conditionCount;
    }

    /** Step 3: one CareBarrier per "yes" answer, linked to the org's matching CareBarrierType if one exists. */
    private static Integer createBarriers(Id patientId, SdohInput s) {
        if (s == null) {
            return 0;
        }
        Map<String, Boolean> answers = new Map<String, Boolean>{
            'transport' => s.transport == true,
            'food' => s.food == true,
            'cost' => s.cost == true,
            'isolation' => s.isolation == true
        };
        List<CareBarrierType> types = [SELECT Id, Name FROM CareBarrierType WITH USER_MODE LIMIT 500];
        List<SObject> barriers = new List<SObject>();
        for (String key : answers.keySet()) {
            if (!answers.get(key)) {
                continue;
            }
            barriers.add(new CareBarrier(
                Name = SDOH_BARRIER_NAMES.get(key),
                PatientId = patientId,
                CareBarrierTypeId = findBarrierType(types, SDOH_KEYWORDS.get(key)),
                Status = 'Open',
                Priority = 'High',
                IsActive = true,
                EffectiveFrom = Date.today(),
                Description = String.isBlank(s.notes) ? 'Identified during onboarding SDOH screening.' : s.notes
            ));
        }
        insertUserMode(barriers);
        return barriers.size();
    }

    /** Returns the first barrier type whose name contains the keyword (case-insensitive), or null. */
    @TestVisible
    private static Id findBarrierType(List<CareBarrierType> types, String keyword) {
        for (CareBarrierType t : types) {
            if (t.Name != null && t.Name.containsIgnoreCase(keyword)) {
                return t.Id;
            }
        }
        return null;
    }

    /** Step 5a: enrol in the chosen program. Re-uses an existing enrolment if the patient is already in it. */
    // public: also used by ProgramEnrollmentController (enrol an existing patient in another program)
    public static CareProgramEnrollee enrol(Account patient, Id careProgramId) {
        List<CareProgramEnrollee> existing = [
            SELECT Id FROM CareProgramEnrollee
            WHERE AccountId = :patient.Id AND CareProgramId = :careProgramId
            WITH USER_MODE LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0];
        }
        CareProgram program = [SELECT Name FROM CareProgram WHERE Id = :careProgramId WITH USER_MODE LIMIT 1];
        CareProgramEnrollee e = new CareProgramEnrollee(
            Name = (patient.Name + ' - ' + program.Name).left(255),
            CareProgramId = careProgramId,
            AccountId = patient.Id,
            Status = 'Active'
        );
        insertUserMode(new List<SObject>{ e });
        return e;
    }

    /**
     * Step 4: record consent with Health Cloud's standard consent objects:
     *   AuthorizationForm (the document) -> AuthorizationFormText (one wording) -> AuthorizationFormConsent (the patient's answer).
     * The consent giver is the CareProgramEnrollee, so consent is tied to this specific program enrolment.
     */
    // public: shared with ProgramEnrollmentController
    public static Integer recordConsent(Id enrolleeId, ConsentInput c) {
        Map<String, Id> textIds = getOrCreateConsentTexts();
        String source = String.isBlank(c.capturedSource) ? 'InPerson' : c.capturedSource;
        List<SObject> consents = new List<SObject>{
            buildConsent(enrolleeId, textIds.get(PROGRAM_CONSENT_TEXT), PROGRAM_CONSENT_TEXT, source)
        };
        if (c.contactConsent == true) {
            consents.add(buildConsent(enrolleeId, textIds.get(CONTACT_CONSENT_TEXT), CONTACT_CONSENT_TEXT, source));
        }
        insertUserMode(consents);
        return consents.size();
    }

    private static AuthorizationFormConsent buildConsent(Id enrolleeId, Id textId, String label, String source) {
        return new AuthorizationFormConsent(
            Name = label,
            ConsentGiverId = enrolleeId,
            AuthorizationFormTextId = textId,
            Status = 'Signed',
            ConsentCapturedDateTime = Datetime.now(),
            ConsentCapturedSourceType = source,
            ConsentCapturedSource = 'Patient onboarding wizard'
        );
    }

    /** Creates the consent form and its two texts the first time; afterwards just looks them up. */
    @TestVisible
    private static Map<String, Id> getOrCreateConsentTexts() {
        List<AuthorizationForm> forms = [SELECT Id FROM AuthorizationForm WHERE Name = :CONSENT_FORM_NAME LIMIT 1];
        AuthorizationForm form;
        if (forms.isEmpty()) {
            form = new AuthorizationForm(Name = CONSENT_FORM_NAME, IsSignatureRequired = false);
            insert form; // system mode: coordinators record consent but don't maintain consent forms
        } else {
            form = forms[0];
        }
        Map<String, Id> idsByName = new Map<String, Id>();
        for (AuthorizationFormText t : [
            SELECT Id, Name FROM AuthorizationFormText WHERE AuthorizationFormId = :form.Id
        ]) {
            idsByName.put(t.Name, t.Id);
        }
        // Salesforce requires the actual wording on each text (a summary, full text, URL or file) and a locale,
        // so the record shows exactly what the patient agreed to. Example: SummaryAuthFormText below.
        List<AuthorizationFormText> missing = new List<AuthorizationFormText>();
        for (String textName : CONSENT_WORDING.keySet()) {
            if (!idsByName.containsKey(textName)) {
                missing.add(new AuthorizationFormText(
                    Name = textName,
                    AuthorizationFormId = form.Id,
                    IsActive = true,
                    Locale = 'en_US', // required in practice: without a locale the insert fails with an internal error
                    SummaryAuthFormText = CONSENT_WORDING.get(textName).left(255)
                ));
            }
        }
        if (!missing.isEmpty()) {
            insert missing;
            for (AuthorizationFormText t : missing) {
                idsByName.put(t.Name, t.Id);
            }
        }
        return idsByName;
    }

    /** Step 5b: care plans belong to a care coordination Case (CarePlan.CaseId is master-detail). */
    // public: shared with ProgramEnrollmentController
    public static Id createCarePlan(Account patient, Id templateId) {
        CarePlanTemplate t = [SELECT Name FROM CarePlanTemplate WHERE Id = :templateId WITH USER_MODE LIMIT 1];
        Case c = new Case(
            Subject = ('Care coordination: ' + patient.Name).left(255),
            AccountId = patient.Id,
            ContactId = patient.PersonContactId,
            Status = 'New'
        );
        insertUserMode(new List<SObject>{ c });
        CarePlan cp = new CarePlan(
            Name = (t.Name + ' for ' + patient.Name).left(255),
            CaseId = c.Id,
            ParticipantId = patient.Id,
            CarePlanTemplateId = templateId,
            Status = 'Active'
        );
        insertUserMode(new List<SObject>{ cp });
        return cp.Id;
    }

    // ============================================================ Helpers

    /**
     * Builds an AuraHandledException whose message is readable in BOTH places:
     * the LWC (error.body.message) and Apex tests / debug logs (e.getMessage()).
     * Without setMessage, getMessage() would only return "Script-thrown exception".
     */
    public static AuraHandledException auraError(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    /** Inserts with the running user's object and field permissions enforced (USER_MODE). */
    private static void insertUserMode(List<SObject> records) {
        if (records != null && !records.isEmpty()) {
            Database.insert(records, AccessLevel.USER_MODE);
        }
    }
}
