import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getDashboard from '@salesforce/apex/CareCoordinatorController.getDashboard';
import logOutreach from '@salesforce/apex/CareCoordinatorController.logOutreach';

const HIGH_RISK = 70;

const COLUMNS = [
    { label: 'Patient', fieldName: 'name', type: 'text' },
    { label: 'MRN', fieldName: 'mrn', type: 'text', initialWidth: 130 },
    {
        label: 'Risk',
        fieldName: 'riskScore',
        type: 'number',
        initialWidth: 80,
        cellAttributes: { class: { fieldName: 'riskClass' } }
    },
    { label: 'Care Gap', fieldName: 'gapLabel', type: 'text', initialWidth: 130 },
    { label: 'Last HbA1c', fieldName: 'lastHbA1cDate', type: 'date-local', initialWidth: 120 },
    {
        label: 'HbA1c %',
        fieldName: 'lastHbA1cValue',
        type: 'number',
        initialWidth: 90,
        typeAttributes: { minimumFractionDigits: 1, maximumFractionDigits: 1 }
    },
    { label: 'Open Tasks', fieldName: 'openTasks', type: 'number', initialWidth: 100 },
    {
        type: 'action',
        typeAttributes: {
            rowActions: [
                { label: 'Open patient', name: 'open' },
                { label: 'Log outreach call', name: 'log' }
            ]
        }
    }
];

export default class CareCoordinatorDashboard extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    summary;
    patients = [];
    error;
    isLoading = true;
    showOnlyGaps = false;
    wiredResult;

    @wire(getDashboard)
    wiredDashboard(result) {
        this.wiredResult = result;
        this.isLoading = false;
        if (result.data) {
            this.summary = result.data;
            this.patients = result.data.patients.map((p) => ({
                ...p,
                gapLabel: p.careGapOpen ? 'HbA1c overdue' : 'Up to date',
                riskClass: p.riskScore >= HIGH_RISK ? 'slds-text-color_error slds-text-title_bold' : ''
            }));
            this.error = undefined;
        } else if (result.error) {
            this.error = this.reduceError(result.error);
            this.summary = undefined;
        }
    }

    get tiles() {
        const s = this.summary;
        return [
            { label: 'Patients', value: s.totalPatients, boxClass: 'slds-box slds-theme_shade' },
            { label: 'High risk (70+)', value: s.highRiskPatients, boxClass: 'slds-box slds-theme_shade' },
            { label: 'Open care gaps', value: s.openCareGaps, boxClass: 'slds-box slds-theme_shade' },
            { label: 'Open tasks', value: s.openTasks, boxClass: 'slds-box slds-theme_shade' }
        ];
    }

    get rows() {
        return this.showOnlyGaps ? this.patients.filter((p) => p.careGapOpen) : this.patients;
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    handleToggle(event) {
        this.showOnlyGaps = event.target.checked;
    }

    handleRefresh() {
        this.isLoading = true;
        refreshApex(this.wiredResult).finally(() => {
            this.isLoading = false;
        });
    }

    async handleRowAction(event) {
        const { action, row } = event.detail;
        if (action.name === 'open') {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: row.id, objectApiName: 'Account', actionName: 'view' }
            });
        } else if (action.name === 'log') {
            try {
                await logOutreach({
                    accountId: row.id,
                    notes: 'Outreach call logged from the Care Coordinator dashboard.'
                });
                this.toast('Outreach logged', `Call logged for ${row.name}.`, 'success');
                await refreshApex(this.wiredResult);
            } catch (e) {
                this.toast('Could not log outreach', this.reduceError(e), 'error');
            }
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        return error?.message || 'Unknown error';
    }
}
