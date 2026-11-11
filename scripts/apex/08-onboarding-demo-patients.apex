// Demo patients created THROUGH the wizard Apex (same records the screens create). Run after 07.
//  - Leela Joshi  (EPIC-100021): new patient, diabetes + hypertension, HbA1c 8.1, transport + cost barriers -> Diabetes program
//  - Farhan Sheikh (EPIC-100022): new patient, hypertension + cholesterol, food + isolation barriers -> Hypertension program
//  - Priya Singh (EPIC-100002) and Vikram Rao (EPIC-100005): existing patients added to the Hypertension program
Id diabetesProgram = [SELECT Id FROM CareProgram WHERE Name = 'Diabetes Management Program' LIMIT 1].Id;
Id htnProgram = [SELECT Id FROM CareProgram WHERE Name = 'Hypertension Management Program' LIMIT 1].Id;
Id diabetesPlan = [SELECT Id FROM CarePlanTemplate WHERE Name = 'Type 2 Diabetes Care Plan' LIMIT 1].Id;
Id htnPlan = [SELECT Id FROM CarePlanTemplate WHERE Name = 'Hypertension Care Plan' LIMIT 1].Id;

if ([SELECT COUNT() FROM Account WHERE Epic_MRN__c = 'EPIC-100021'] == 0) {
    PatientOnboardingController.OnboardingRequest r = new PatientOnboardingController.OnboardingRequest();
    r.patient = new PatientOnboardingController.PatientInput();
    r.patient.firstName = 'Leela'; r.patient.lastName = 'Joshi'; r.patient.birthDate = Date.newInstance(1979, 3, 2);
    r.patient.mrn = 'EPIC-100021'; r.patient.phone = '9876543210'; r.patient.email = 'leela.joshi@example.com'; r.patient.city = 'Pune';
    r.clinical = new PatientOnboardingController.ClinicalInput();
    r.clinical.conditionCodes = new List<String>{ '44054006', '38341003' };
    r.clinical.onsetDate = Date.today().addYears(-3); r.clinical.hba1cValue = 8.1; r.clinical.hba1cDate = Date.today().addDays(-10);
    r.sdoh = new PatientOnboardingController.SdohInput();
    r.sdoh.transport = true; r.sdoh.cost = true; r.sdoh.food = false; r.sdoh.isolation = false;
    r.sdoh.notes = 'Son drives her on weekends only; prefers Saturday lab slots. Cuts metformin tablets to make them last.';
    r.consent = new PatientOnboardingController.ConsentInput();
    r.consent.programConsent = true; r.consent.contactConsent = true; r.consent.capturedSource = 'Phone';
    r.program = new PatientOnboardingController.ProgramInput();
    r.program.careProgramId = diabetesProgram; r.program.carePlanTemplateId = diabetesPlan; r.program.scheduleWelcomeCall = true;
    PatientOnboardingController.submitOnboarding(JSON.serialize(r));
}

if ([SELECT COUNT() FROM Account WHERE Epic_MRN__c = 'EPIC-100022'] == 0) {
    PatientOnboardingController.OnboardingRequest r = new PatientOnboardingController.OnboardingRequest();
    r.patient = new PatientOnboardingController.PatientInput();
    r.patient.firstName = 'Farhan'; r.patient.lastName = 'Sheikh'; r.patient.birthDate = Date.newInstance(1968, 11, 20);
    r.patient.mrn = 'EPIC-100022'; r.patient.phone = '9123456780'; r.patient.city = 'Mumbai';
    r.clinical = new PatientOnboardingController.ClinicalInput();
    r.clinical.conditionCodes = new List<String>{ '38341003', '13644009' };
    r.clinical.onsetDate = Date.today().addYears(-5);
    r.sdoh = new PatientOnboardingController.SdohInput();
    r.sdoh.transport = false; r.sdoh.cost = false; r.sdoh.food = true; r.sdoh.isolation = true;
    r.sdoh.notes = 'Widower, lives alone; eats mostly packaged food.';
    r.consent = new PatientOnboardingController.ConsentInput();
    r.consent.programConsent = true; r.consent.contactConsent = false; r.consent.capturedSource = 'InPerson';
    r.program = new PatientOnboardingController.ProgramInput();
    r.program.careProgramId = htnProgram; r.program.carePlanTemplateId = htnPlan; r.program.scheduleWelcomeCall = true;
    PatientOnboardingController.submitOnboarding(JSON.serialize(r));
}

Map<String, Id> templateByMrn = new Map<String, Id>{ 'EPIC-100002' => htnPlan, 'EPIC-100005' => null };
Map<String, String> sourceByMrn = new Map<String, String>{ 'EPIC-100002' => 'Video', 'EPIC-100005' => 'Phone' };
for (Account a : [SELECT Id, Epic_MRN__c FROM Account WHERE Epic_MRN__c IN :templateByMrn.keySet()]) {
    if ([SELECT COUNT() FROM CareProgramEnrollee WHERE AccountId = :a.Id AND CareProgramId = :htnProgram] > 0) {
        continue;
    }
    ProgramEnrollmentController.EnrollmentRequest e = new ProgramEnrollmentController.EnrollmentRequest();
    e.patientId = a.Id; e.careProgramId = htnProgram; e.carePlanTemplateId = templateByMrn.get(a.Epic_MRN__c);
    e.programConsent = true; e.contactConsent = true; e.capturedSource = sourceByMrn.get(a.Epic_MRN__c); e.scheduleWelcomeCall = true;
    ProgramEnrollmentController.enrollPatient(JSON.serialize(e));
}
