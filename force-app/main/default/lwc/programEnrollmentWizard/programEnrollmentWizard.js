/**
 * programEnrollmentWizard
 * ---------------------------------------------------------------------------------------------
 * Lives on the PATIENT (person account) record page. Enrols the patient you are looking at
 * in ANOTHER care program, in 3 short steps:
 *
 *   Step 1  Program  - see current programs, pick a new one (already-joined programs are hidden)
 *   Step 2  Consent  - program consent (required) + phone/SMS consent
 *   Step 3  Review   - optional care plan + welcome call, then Enrol
 *
 * Why a separate component from patientOnboardingWizard?
 *   Onboarding = brand-new patient (record, history, SDOH, consent, program).
 *   This       = existing patient, just one more program. No search, no re-entering history.
 *
 * Best practices used:
 *   - @api recordId: the record page passes in the patient's Id automatically.
 *   - @wire + refreshApex: data is cached, and refreshed after we enrol so the badges update.
 *   - notifyRecordUpdateAvailable: tells other components on the page (related lists etc.) to refresh.
 *   - Immutable form updates, per-step validation, one Apex call that is all-or-nothing.
 */
import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getEnrollmentContext from '@salesforce/apex/ProgramEnrollmentController.getEnrollmentContext';
import enrollPatient from '@salesforce/apex/ProgramEnrollmentController.enrollPatient';

const STEPS = [
    { value: '1', label: 'Program', title: 'Choose a program', tip: 'Programs this patient is already in are shown as badges and cannot be picked again.' },
    { value: '2', label: 'Consent', title: 'Program consent', tip: 'Every program needs its own consent, because consent is linked to the enrolment, not just to the patient.' },
    { value: '3', label: 'Review', title: 'Review & enrol', tip: 'Optionally start a care plan and a welcome call. Nothing is saved until you click Enrol.' }
];

/** Must match AuthorizationFormConsent.ConsentCapturedSourceType picklist API names. */
const CONSENT_SOURCES = [
    { label: 'In person', value: 'InPerson' },
    { label: 'Phone', value: 'Phone' },
    { label: 'Video', value: 'Video' },
    { label: 'Email', value: 'Email' },
    { label: 'Web', value: 'Web' }
];

function emptyForm() {
    return {
        careProgramId: null,
        programConsent: false,
        contactConsent: false,
        capturedSource: 'InPerson',
        carePlanTemplateId: null,
        scheduleWelcomeCall: true
    };
}

export default class ProgramEnrollmentWizard extends NavigationMixin(LightningElement) {
    /** Set automatically by the Lightning record page. Example: '001KO00000AbCdE' */
    @api recordId;

    steps = STEPS;
    consentSources = CONSENT_SOURCES;
    currentStep = '1';
    form = emptyForm();

    context;          // EnrollmentContext from Apex
    loadError;
    wiredContextResult; // kept so refreshApex() can re-run the wire
    isSaving = false;
    result;           // EnrollmentResult after a successful enrolment

    // ============================================================ Data

    /**
     * '$recordId' (with $) makes the wire reactive: if the page's record changes, it reloads.
     * Example data: { patientName: 'Aarav Nair', currentEnrollments: [{ programName: 'Diabetes…' }], availablePrograms: [...] }
     */
    @wire(getEnrollmentContext, { patientId: '$recordId' })
    wiredContext(value) {
        this.wiredContextResult = value; // store the whole object for refreshApex
        const { data, error } = value;
        if (data) {
            this.context = data;
            this.loadError = undefined;
        } else if (error) {
            this.loadError = this.reduceError(error);
        }
    }

    // ============================================================ Getters for the template

    get isLoading() {
        return !this.context && !this.loadError;
    }
    get isPatient() {
        return this.context && this.context.isPatient;
    }
    get notAPatient() {
        return this.context && !this.context.isPatient;
    }
    get hasCurrentEnrollments() {
        return this.context && this.context.currentEnrollments.length > 0;
    }
    get currentEnrollments() {
        // Add a CSS class per status so Active shows green, others grey.
        return (this.context ? this.context.currentEnrollments : []).map((e) => ({
            ...e,
            badgeClass: e.status === 'Active' ? 'enrolled-badge enrolled-badge_active' : 'enrolled-badge'
        }));
    }
    get noProgramsLeft() {
        return this.context && this.context.availablePrograms.length === 0;
    }
    /** Program tiles; "selected" drives the highlighted style. */
    get programTiles() {
        return (this.context ? this.context.availablePrograms : []).map((p) => {
            const selected = p.id === this.form.careProgramId;
            return {
                ...p,
                selected,
                tileClass: selected ? 'program-tile program-tile_selected' : 'program-tile',
                ariaPressed: selected ? 'true' : 'false',
                dates: p.endDate ? `${p.startDate} → ${p.endDate}` : p.startDate ? `Since ${p.startDate}` : '',
                description: p.description || 'No description provided.'
            };
        });
    }
    get selectedProgram() {
        return (this.context ? this.context.availablePrograms : []).find((p) => p.id === this.form.careProgramId);
    }
    get selectedProgramName() {
        return this.selectedProgram ? this.selectedProgram.name : '';
    }
    get carePlanOptions() {
        return [{ label: '— No care plan —', value: '' }, ...(this.context ? this.context.carePlanTemplates : [])];
    }
    get carePlanValue() {
        return this.form.carePlanTemplateId || '';
    }
    get consentSourceLabel() {
        return (CONSENT_SOURCES.find((s) => s.value === this.form.capturedSource) || {}).label;
    }
    get carePlanLabel() {
        const t = this.carePlanOptions.find((o) => o.value === this.carePlanValue);
        return t ? t.label : '';
    }

    get activeStep() { return STEPS[Number(this.currentStep) - 1]; }
    get stepCounter() { return `Step ${this.currentStep} of ${STEPS.length}`; }
    get isStep1() { return this.currentStep === '1'; }
    get isStep2() { return this.currentStep === '2'; }
    get isStep3() { return this.currentStep === '3'; }
    get isFirstStep() { return this.currentStep === '1'; }
    get isLastStep() { return this.currentStep === '3'; }
    get showWizard() { return !this.result; }
    get yesNoContact() { return this.form.contactConsent ? 'Given' : 'Not given'; }
    get yesNoWelcome() { return this.form.scheduleWelcomeCall ? 'Yes, in 2 days' : 'No'; }

    // ============================================================ Handlers

    /** Clicking a program tile selects it. data-id holds the CareProgram Id. */
    handleSelectProgram(event) {
        this.updateField('careProgramId', event.currentTarget.dataset.id);
    }

    /** Keyboard support: Enter or Space on a focused tile selects it (accessibility). */
    handleTileKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleSelectProgram(event);
        }
    }

    /**
     * One handler for checkboxes, toggles and comboboxes. data-field names the form property.
     * Example: ticking "Patient gives program consent" -> updateField('programConsent', true)
     */
    handleChange(event) {
        const field = event.target.dataset.field;
        const isCheck = event.target.type === 'checkbox' || event.target.type === 'toggle';
        let value = isCheck ? event.target.checked : event.detail.value;
        this.updateField(field, value === '' ? null : value);
    }

    updateField(field, value) {
        this.form = { ...this.form, [field]: value }; // immutable update -> reliable re-render
    }

    handleNext() {
        if (!this.validateCurrentStep()) return;
        this.currentStep = String(Number(this.currentStep) + 1);
    }

    handleBack() {
        this.currentStep = String(Number(this.currentStep) - 1);
    }

    handleEdit(event) {
        this.currentStep = event.currentTarget.dataset.step;
    }

    validateCurrentStep() {
        if (this.isStep1 && !this.form.careProgramId) {
            this.toast('Choose a program', 'Select the program to enrol the patient in.', 'warning');
            return false;
        }
        const inputs = [...this.template.querySelectorAll('lightning-input, lightning-combobox')];
        const valid = inputs.reduce((ok, input) => input.reportValidity() && ok, true);
        if (!valid) {
            this.toast('Check this step', 'Please fix the highlighted fields.', 'error');
        }
        return valid;
    }

    /** Sends the form to Apex. Example payload: { patientId, careProgramId, programConsent: true, ... } */
    async handleEnroll() {
        this.isSaving = true;
        try {
            this.result = await enrollPatient({
                requestJson: JSON.stringify({ ...this.form, patientId: this.recordId })
            });
            this.toast('Enrolled', `${this.context.patientName} is now in ${this.result.programName}.`, 'success');
            // Refresh our own data (badges) and tell the rest of the page the record changed.
            await refreshApex(this.wiredContextResult);
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } catch (error) {
            this.toast('Enrolment was not saved', this.reduceError(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    handleViewEnrollment() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.result.enrolleeId, objectApiName: 'CareProgramEnrollee', actionName: 'view' }
        });
    }

    handleStartOver() {
        this.form = emptyForm();
        this.result = undefined;
        this.currentStep = '1';
    }

    // ============================================================ Utilities

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    /** Example: { body: { message: 'Program consent is required…' } } -> 'Program consent is required…' */
    reduceError(error) {
        if (!error) return 'Unknown error';
        if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(', ');
        if (error.body && error.body.message) return error.body.message;
        return error.message || JSON.stringify(error);
    }
}
