/**
 * patientOnboardingWizard
 * ---------------------------------------------------------------------------------------------
 * A 6-step wizard a care coordinator uses to onboard a new patient and enrol them in a care program.
 *
 *   Step 1  Patient    - who is the patient? (with a duplicate check)
 *   Step 2  Clinical   - diagnoses + latest HbA1c
 *   Step 3  SDOH       - social needs screening (transport, food, cost, isolation)
 *   Step 4  Consent    - program consent (required) + contact consent
 *   Step 5  Program    - care program, optional care plan template, welcome call
 *   Step 6  Review     - check everything, then Submit (one Apex call saves it all)
 *
 * Onboarding vs enrolment (handy interview line):
 *   Onboarding = getting a NEW patient set up (record, history, needs, consent).
 *   Enrolment  = adding a patient to a specific CARE PROGRAM (CareProgramEnrollee).
 *   This wizard does both, in that order, in a single transaction.
 *
 * Best practices used in this file:
 *   - All form data lives in ONE object (this.form). We never mutate it in place;
 *     we build a new copy, so LWC reliably re-renders (immutable updates).
 *   - One generic change handler driven by data-* attributes, instead of 20 handlers.
 *   - Validation per step with reportValidity() before moving on.
 *   - @wire for read-only setup data (cached), imperative Apex for the save.
 *   - Friendly errors through a toast, using a helper that understands every error shape.
 */
import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSetupData from '@salesforce/apex/PatientOnboardingController.getSetupData';
import findPatients from '@salesforce/apex/PatientOnboardingController.findPatients';
import submitOnboarding from '@salesforce/apex/PatientOnboardingController.submitOnboarding';

/**
 * Step definitions. "value" is what lightning-progress-indicator uses to know the current step.
 * "tip" is the help text shown in the blue tip box at the top of each step.
 */
const STEPS = [
    {
        value: '1',
        label: 'Patient',
        icon: 'standard:person_account',
        title: 'Patient details',
        tip: 'Search first to avoid duplicates. If the patient already exists (for example imported from Epic), pick them and skip straight to the clinical step.'
    },
    {
        value: '2',
        label: 'Clinical',
        icon: 'standard:medication',
        title: 'Clinical history',
        tip: 'Record the diagnoses the program is for. A recent HbA1c lets the nightly care-gap job calculate risk straight away.'
    },
    {
        value: '3',
        label: 'Social needs',
        icon: 'standard:social',
        title: 'Social determinants of health (SDOH)',
        tip: 'Ask each question in plain words. Every "yes" becomes a Care Barrier so the team can plan around it (for example, arrange transport to the lab).'
    },
    {
        value: '4',
        label: 'Consent',
        icon: 'standard:approval',
        title: 'Consent',
        tip: 'Read the consent text to the patient. Program consent is required before enrolment; contact consent controls phone/SMS outreach.'
    },
    {
        value: '5',
        label: 'Program',
        icon: 'standard:care_request_reviewer',
        title: 'Care program & plan',
        tip: 'Choose the program to enrol in. Adding a care plan template creates the patient’s plan (problems, goals, tasks) right away.'
    },
    {
        value: '6',
        label: 'Review',
        icon: 'standard:task2',
        title: 'Review & submit',
        tip: 'Check every section. Use Edit to jump back. Nothing is saved until you press Submit, and if any part fails nothing is saved at all.'
    }
];

/** SDOH questions. "key" matches the Apex SdohInput property names. */
const SDOH_QUESTIONS = [
    {
        key: 'transport',
        label: 'Difficulty getting to appointments or the lab?',
        help: 'Example: no car, cannot afford a cab, depends on family to drive. Creates a "Transportation" barrier.'
    },
    {
        key: 'food',
        label: 'Worried food will run out before there is money to buy more?',
        help: 'Food insecurity makes a diabetic diet hard to follow. Creates a "Food insecurity" barrier.'
    },
    {
        key: 'cost',
        label: 'Skips or delays medicine because of cost?',
        help: 'Example: cuts tablets in half to make them last. Creates a "Cannot afford medication" barrier.'
    },
    {
        key: 'isolation',
        label: 'Lives alone or has no one to help day to day?',
        help: 'Social isolation affects follow-up and self-care. Creates a "Lives alone / social isolation" barrier.'
    }
];

/** Values must match the AuthorizationFormConsent.ConsentCapturedSourceType picklist API names. */
const CONSENT_SOURCES = [
    { label: 'In person', value: 'InPerson' },
    { label: 'Phone', value: 'Phone' },
    { label: 'Video', value: 'Video' },
    { label: 'Email', value: 'Email' },
    { label: 'Web', value: 'Web' }
];

/** Today's date in the user's time zone as 'YYYY-MM-DD' (toISOString() would use UTC and can be a day off). */
function localIsoDate() {
    const d = new Date();
    const pad = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/**
 * A fresh, empty form. Its shape mirrors PatientOnboardingController.OnboardingRequest,
 * so we can send it to Apex with JSON.stringify(this.form) and no mapping code.
 */
function emptyForm() {
    return {
        patient: {
            existingPatientId: null,
            firstName: '',
            lastName: '',
            birthDate: null,
            mrn: '',
            phone: '',
            email: '',
            city: ''
        },
        clinical: { conditionCodes: [], onsetDate: null, hba1cValue: null, hba1cDate: null },
        sdoh: { transport: false, food: false, cost: false, isolation: false, notes: '' },
        consent: { programConsent: false, contactConsent: false, capturedSource: 'InPerson' },
        program: { careProgramId: null, carePlanTemplateId: null, scheduleWelcomeCall: true }
    };
}

export default class PatientOnboardingWizard extends NavigationMixin(LightningElement) {
    /** Title shown in the card header. Admins can change it in Lightning App Builder (see js-meta.xml). */
    @api cardTitle = 'Patient Onboarding & Program Enrolment';

    steps = STEPS;
    consentSources = CONSENT_SOURCES;
    currentStep = '1';
    form = emptyForm();

    setup = { carePrograms: [], carePlanTemplates: [], conditions: [] };
    setupError;

    matches = [];          // duplicate-check results
    searched = false;      // true once the coordinator has run the duplicate check
    isSearching = false;
    isSaving = false;
    result;                // OnboardingResult from Apex; when set, the success screen shows
    // Phone pattern lives in JS because {braces} inside an HTML attribute would be read as an LWC expression.
    phonePattern = '[0-9+()\\- ]{7,20}'; // allows e.g. '+91 98765 43210' or '(020) 555-0101'
    today = localIsoDate(); // e.g. '2026-11-12', used as the max allowed date

    // ============================================================ Data loading

    /**
     * @wire calls Apex automatically and caches the result (the method is cacheable=true).
     * Example of data: { carePrograms: [{ label: 'Diabetes Management Program', value: '0ZQ...' }] }
     */
    @wire(getSetupData)
    wiredSetup({ data, error }) {
        if (data) {
            this.setup = data;
            this.setupError = undefined;
            // Nice touch: if there is only one program, pre-select it.
            if (data.carePrograms.length === 1 && !this.form.program.careProgramId) {
                this.updateField('program', 'careProgramId', data.carePrograms[0].value);
            }
        } else if (error) {
            this.setupError = this.reduceError(error);
        }
    }

    // ============================================================ Step getters (used by the template)

    get stepIndex() {
        return Number(this.currentStep) - 1; // '1' -> 0
    }
    get activeStep() {
        return STEPS[this.stepIndex];
    }
    get stepCounter() {
        return `Step ${this.currentStep} of ${STEPS.length}`; // e.g. 'Step 2 of 6'
    }
    get progressPercent() {
        return Math.round((this.stepIndex / (STEPS.length - 1)) * 100);
    }
    get progressStyle() {
        return `width: ${this.progressPercent}%`;
    }

    get isStep1() { return this.currentStep === '1'; }
    get isStep2() { return this.currentStep === '2'; }
    get isStep3() { return this.currentStep === '3'; }
    get isStep4() { return this.currentStep === '4'; }
    get isStep5() { return this.currentStep === '5'; }
    get isStep6() { return this.currentStep === '6'; }

    get isFirstStep() { return this.currentStep === '1'; }
    get isLastStep() { return this.currentStep === String(STEPS.length); }
    get showWizard() { return !this.result; }

    // ============================================================ Step 1 helpers

    get isExistingPatient() {
        return !!this.form.patient.existingPatientId;
    }
    get hasMatches() {
        return this.matches.length > 0;
    }
    get noMatchesFound() {
        return this.searched && !this.isSearching && this.matches.length === 0;
    }
    get selectedPatientName() {
        const m = this.matches.find((x) => x.id === this.form.patient.existingPatientId);
        return m ? m.name : '';
    }

    // ============================================================ Step 3 helpers

    /** Adds the current yes/no answer to each question so the template can bind "checked". */
    get sdohQuestions() {
        return SDOH_QUESTIONS.map((q) => ({ ...q, checked: this.form.sdoh[q.key] }));
    }
    get barrierCount() {
        return SDOH_QUESTIONS.filter((q) => this.form.sdoh[q.key]).length;
    }
    get barrierSummary() {
        const n = this.barrierCount;
        return n === 0 ? 'No social barriers identified.' : `${n} care barrier${n > 1 ? 's' : ''} will be created.`;
    }

    // ============================================================ Step 6 (review) helpers

    get review() {
        const { patient, clinical, sdoh, consent, program } = this.form;
        const labelOf = (list, value) => (list.find((o) => o.value === value) || {}).label || '—';
        const conditionLabels = clinical.conditionCodes.map((c) => labelOf(this.setup.conditions, c));
        return {
            patientName: this.isExistingPatient
                ? `${this.selectedPatientName} (existing patient)`
                : `${patient.firstName} ${patient.lastName}`.trim(),
            birthDate: this.isExistingPatient ? 'On file' : patient.birthDate || '—',
            mrn: patient.mrn || '—',
            contact: [patient.phone, patient.email].filter(Boolean).join(' · ') || '—',
            conditions: conditionLabels.length ? conditionLabels.join(', ') : 'None selected',
            hba1c: clinical.hba1cValue ? `${clinical.hba1cValue}% on ${clinical.hba1cDate}` : 'Not recorded',
            barriers: SDOH_QUESTIONS.filter((q) => sdoh[q.key]).map((q) => q.label),
            hasBarriers: this.barrierCount > 0,
            programConsent: consent.programConsent ? 'Given' : 'Missing',
            contactConsent: consent.contactConsent ? 'Given' : 'Not given',
            consentSource: labelOf(CONSENT_SOURCES, consent.capturedSource),
            program: labelOf(this.setup.carePrograms, program.careProgramId),
            carePlan: program.carePlanTemplateId ? labelOf(this.setup.carePlanTemplates, program.carePlanTemplateId) : 'No care plan',
            welcomeCall: program.scheduleWelcomeCall ? 'Yes, in 2 days' : 'No'
        };
    }
    get consentPillClass() {
        return this.form.consent.programConsent ? 'pill pill_ok' : 'pill pill_bad';
    }
    get carePlanTemplateValue() {
        return this.form.program.carePlanTemplateId || '';
    }
    get carePlanTemplateOptions() {
        // First option lets the coordinator choose "no care plan".
        return [{ label: '— No care plan —', value: '' }, ...this.setup.carePlanTemplates];
    }

    // ============================================================ Generic change handler

    /**
     * Every input in the template carries two attributes:
     *   data-section="patient"  data-field="lastName"
     * so one handler updates the right spot in this.form.
     *
     * Example: typing "Joshi" in Last name calls updateField('patient', 'lastName', 'Joshi').
     */
    handleChange(event) {
        const { section, field } = event.target.dataset;
        let value;
        if (event.target.type === 'checkbox' || event.target.type === 'toggle') {
            value = event.target.checked;          // checkboxes/toggles give true/false
        } else if (event.target.type === 'number') {
            value = event.target.value === '' ? null : Number(event.target.value); // '8.1' -> 8.1
        } else {
            value = event.detail && event.detail.value !== undefined ? event.detail.value : event.target.value;
        }
        this.updateField(section, field, value === '' ? null : value);
    }

    /** Checkbox groups and comboboxes return their value in event.detail.value. */
    handleDetailChange(event) {
        const { section, field } = event.target.dataset;
        const value = event.detail.value;
        // '' means "nothing chosen" (e.g. "No care plan"); Apex expects null, not an empty Id.
        this.updateField(section, field, value === '' ? null : value);
    }

    /**
     * Immutable update: copy the form, copy the section, change one field.
     * Before: { patient: { lastName: '' } }  ->  After: { patient: { lastName: 'Joshi' } } (a new object)
     */
    updateField(section, field, value) {
        this.form = { ...this.form, [section]: { ...this.form[section], [field]: value } };
    }

    // ============================================================ Duplicate check (step 1)

    /**
     * Searches by MRN, or by last name + date of birth.
     * Example: MRN 'EPIC-100001' finds Aarav Nair, who was imported from Epic.
     */
    async handleSearch() {
        const { mrn, lastName, birthDate } = this.form.patient;
        if (!mrn && !(lastName && birthDate)) {
            this.toast('Add search details', 'Enter an MRN, or a last name and date of birth, then search.', 'warning');
            return;
        }
        this.isSearching = true;
        try {
            this.matches = await findPatients({ mrn, lastName, birthDate });
            this.searched = true;
        } catch (error) {
            this.toast('Search failed', this.reduceError(error), 'error');
        } finally {
            this.isSearching = false;
        }
    }

    /** "Use this patient" button: data-id holds the Account Id of the match. */
    handleSelectMatch(event) {
        this.updateField('patient', 'existingPatientId', event.currentTarget.dataset.id);
        this.toast('Existing patient selected', 'Continue with the clinical details.', 'info');
    }

    handleClearMatch() {
        this.updateField('patient', 'existingPatientId', null);
    }

    // ============================================================ Navigation between steps

    handleNext() {
        if (!this.validateCurrentStep()) {
            return; // stay on this step; errors are shown under the fields
        }
        this.currentStep = String(this.stepIndex + 2); // '1' -> '2'
        this.scrollToTop();
    }

    handleBack() {
        this.currentStep = String(this.stepIndex); // '2' -> '1'
        this.scrollToTop();
    }

    /** "Edit" buttons on the review page carry data-step="2" etc. */
    handleGoToStep(event) {
        const target = event.currentTarget.dataset.step;
        // Only allow jumping BACK; jumping forward would skip validation.
        if (Number(target) < Number(this.currentStep)) {
            this.currentStep = String(target);
            this.scrollToTop();
        }
    }

    /**
     * Validates only the fields of the step on screen (other steps are not rendered).
     * reportValidity() shows the red error text and returns false if the field is invalid.
     * Example: Last name is empty -> "Complete this field." appears and we stay on step 1.
     */
    validateCurrentStep() {
        // Step-specific rules that the base components cannot express on their own.
        if (this.isStep1 && this.isExistingPatient) {
            return true; // existing patient: nothing more to fill in
        }
        if (this.isStep2) {
            const dateInput = this.template.querySelector('[data-field="hba1cDate"]');
            const { hba1cValue, hba1cDate } = this.form.clinical;
            // Example: HbA1c 8.1 entered but no date -> ask for the date.
            dateInput.setCustomValidity(hba1cValue && !hba1cDate ? 'Enter the date the HbA1c was taken.' : '');
        }

        const inputs = [
            ...this.template.querySelectorAll(
                'lightning-input, lightning-combobox, lightning-textarea, lightning-checkbox-group'
            )
        ];
        const allValid = inputs.reduce((valid, input) => input.reportValidity() && valid, true);
        if (!allValid) {
            this.toast('Check this step', 'Please fix the highlighted fields before continuing.', 'error');
        }
        return allValid;
    }

    // ============================================================ Submit

    /**
     * Sends the whole form to Apex as JSON. Apex saves everything in one transaction.
     * Example result: { patientId: '001...', patientName: 'Leela Joshi', conditionsCreated: 2, ... }
     */
    async handleSubmit() {
        if (!this.form.consent.programConsent) {
            this.toast('Consent missing', 'Program consent is required. Go back to the Consent step.', 'error');
            return;
        }
        this.isSaving = true;
        try {
            this.result = await submitOnboarding({ requestJson: JSON.stringify(this.form) });
            this.toast('Patient onboarded', `${this.result.patientName} is enrolled in the program.`, 'success');
        } catch (error) {
            this.toast('Onboarding was not saved', this.reduceError(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    // ============================================================ Success screen

    get successStats() {
        const r = this.result || {};
        return [
            { key: 'c', label: 'Conditions', value: r.conditionsCreated, icon: 'standard:medication' },
            { key: 'b', label: 'Care barriers', value: r.barriersCreated, icon: 'standard:social' },
            { key: 'k', label: 'Consents', value: r.consentsCreated, icon: 'standard:approval' },
            { key: 'p', label: 'Care plan', value: r.carePlanId ? 1 : 0, icon: 'standard:care_request_reviewer' }
        ];
    }

    /** Opens the patient's record page using NavigationMixin (no hard-coded URLs). */
    handleViewPatient() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.result.patientId, objectApiName: 'Account', actionName: 'view' }
        });
    }

    /** Resets everything so the coordinator can onboard the next patient. */
    handleStartOver() {
        const programId = this.setup.carePrograms.length === 1 ? this.setup.carePrograms[0].value : null;
        this.form = emptyForm();
        this.updateField('program', 'careProgramId', programId);
        this.matches = [];
        this.searched = false;
        this.result = undefined;
        this.currentStep = '1';
    }

    // ============================================================ Utilities

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    scrollToTop() {
        const top = this.template.querySelector('.wizard-top');
        if (top && top.scrollIntoView) {
            top.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
    }

    /**
     * Turns any Apex/LDS error into readable text.
     * Examples:
     *   { body: { message: 'Program consent is required…' } }  -> 'Program consent is required…'
     *   { body: [{ message: 'A' }, { message: 'B' }] }           -> 'A, B'
     */
    reduceError(error) {
        if (!error) return 'Unknown error';
        if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(', ');
        if (error.body && error.body.message) return error.body.message;
        return error.message || JSON.stringify(error);
    }
}
