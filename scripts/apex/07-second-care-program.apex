// Demo setup for the onboarding + enrolment wizards. Safe to run twice: only creates what is missing.
//  - Hypertension Management Program + Hypertension Care Plan template
//  - "Social isolation" care barrier type (for the SDOH "lives alone" question)
//  - Consent form "Patient Onboarding Consents" with its two texts (wording + Locale are required)
if ([SELECT COUNT() FROM CareProgram WHERE Name = 'Hypertension Management Program'] == 0) {
    insert new CareProgram(Name = 'Hypertension Management Program', Status = 'In Progress', StartDate = Date.today(),
        Description = 'Blood pressure control for adults with hypertension: home BP readings, medication review every 3 months, salt and lifestyle coaching.');
}
if ([SELECT COUNT() FROM CarePlanTemplate WHERE Name = 'Hypertension Care Plan'] == 0) {
    insert new CarePlanTemplate(Name = 'Hypertension Care Plan', Status = 'Published',
        Description = 'Problem: high blood pressure. Goal: BP below 130/80 within 3 months. Tasks: home BP log, medication review, diet coaching.');
}
if ([SELECT COUNT() FROM CareBarrierType WHERE Name LIKE '%isolation%'] == 0) {
    insert new CareBarrierType(Name = 'Social isolation', CodeType = 'SNOMED CT', IsActive = true,
        Description = 'Lives alone or has no one to help with day-to-day care.');
}
List<AuthorizationForm> forms = [SELECT Id FROM AuthorizationForm WHERE Name = 'Patient Onboarding Consents' LIMIT 1];
AuthorizationForm consentForm = forms.isEmpty() ? new AuthorizationForm(Name = 'Patient Onboarding Consents', IsSignatureRequired = false) : forms[0];
if (forms.isEmpty()) {
    insert consentForm;
}
Map<String, String> wording = new Map<String, String>{
    'Care Program Participation Consent' => 'I agree to join the care program. My care team may review my health information, contact me about tests and appointments, and share information with my doctors to coordinate my care. I can withdraw at any time.',
    'Phone and SMS Contact Consent' => 'I agree that my care team may contact me by phone call and SMS about my care, appointments and test reminders.'
};
Set<String> existing = new Set<String>();
for (AuthorizationFormText t : [SELECT Name FROM AuthorizationFormText WHERE AuthorizationFormId = :consentForm.Id]) {
    existing.add(t.Name);
}
for (String textName : wording.keySet()) {
    if (!existing.contains(textName)) {
        insert new AuthorizationFormText(Name = textName, AuthorizationFormId = consentForm.Id, IsActive = true,
            Locale = 'en_US', SummaryAuthFormText = wording.get(textName));
    }
}
