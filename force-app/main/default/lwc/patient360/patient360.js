/**
 * patient360
 * ---------------------------------------------------------------------------------------------
 * A "Patient 360" card for the patient (person account) record page. One look tells a coordinator:
 *
 *   Header   - who the patient is (name, MRN, age, city, phone, email) + risk gauge + care gap flag
 *   KPIs     - last HbA1c, next HbA1c due, programs, open tasks
 *   Sections - HbA1c trend chart, diagnoses, programs + consent, social needs (SDOH),
 *              care plans, open tasks
 *   Actions  - log an outreach call, refresh, click any row to open that record
 *
 * Best practices used:
 *   - ONE cacheable Apex call (@wire) returns all sections, so the page loads in a single round trip.
 *   - The chart is plain SVG computed in JS: no third-party library, nothing to load.
 *   - refreshApex after logging a call, so the numbers update without reloading the page.
 *   - Layout uses CSS grid "auto-fit", so it adapts to the WIDTH OF ITS REGION on the page
 *     (narrow sidebar = 1 column, wide main region = 2-3 columns), not just the screen size.
 */
import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getPatient360 from '@salesforce/apex/Patient360Controller.getPatient360';
import logOutreach from '@salesforce/apex/CareCoordinatorController.logOutreach';

// HbA1c bands (%), used for colours and the help text. Example: 8.1 -> 'high'.
const HBA1C_TARGET = 7;       // usual goal for people with diabetes
const HBA1C_HIGH = 8;         // poorly controlled
const CHART = { width: 320, height: 150, padX: 34, padTop: 18, padBottom: 30 };

/** Formats '2026-11-02' as '2 Nov 2026' in the user's locale. */
function formatDate(value) {
    if (!value) return '—';
    const [y, m, d] = value.split('-').map(Number);
    return new Date(y, m - 1, d).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
}

/** Whole days from today to a 'YYYY-MM-DD' date. Negative = in the past. */
function daysFromToday(value) {
    if (!value) return null;
    const [y, m, d] = value.split('-').map(Number);
    const target = new Date(y, m - 1, d);
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return Math.round((target - today) / 86400000);
}

export default class Patient360 extends NavigationMixin(LightningElement) {
    /** Set by the record page. Example: '001kO000000iZriQAE' (Aarav Nair) */
    @api recordId;

    patient;
    error;
    wiredResult;          // kept for refreshApex
    showOutreach = false; // inline "log a call" panel
    outreachNotes = '';
    isSaving = false;

    // ============================================================ Data

    @wire(getPatient360, { patientId: '$recordId' })
    wiredPatient(value) {
        this.wiredResult = value;
        const { data, error } = value;
        if (data) {
            this.patient = data;
            this.error = undefined;
        } else if (error) {
            this.error = this.reduceError(error);
            this.patient = undefined;
        }
    }

    get isLoading() {
        return !this.patient && !this.error;
    }

    // ============================================================ Header

    /** Initials for the avatar. Example: 'Aarav Nair' -> 'AN' */
    get initials() {
        return (this.patient.name || '?')
            .split(' ')
            .filter(Boolean)
            .slice(0, 2)
            .map((w) => w[0].toUpperCase())
            .join('');
    }
    get ageLabel() {
        const p = this.patient;
        return p.age !== null && p.age !== undefined ? `${p.age} yrs · born ${formatDate(p.birthDate)}` : 'Age unknown';
    }
    get phoneHref() {
        return this.patient.phone ? `tel:${this.patient.phone.replace(/\s/g, '')}` : null;
    }
    get emailHref() {
        return this.patient.email ? `mailto:${this.patient.email}` : null;
    }

    /**
     * Risk gauge: an SVG circle whose coloured arc length = score / 100.
     * Example: score 70 -> 70% of the ring is filled, in red (High).
     */
    get riskScoreLabel() {
        return this.patient.riskScore === null || this.patient.riskScore === undefined ? '—' : Math.round(this.patient.riskScore);
    }
    get gaugeDash() {
        const circumference = 2 * Math.PI * 34; // r = 34 in the template
        const pct = Math.min(Math.max(Number(this.patient.riskScore) || 0, 0), 100) / 100;
        return `${(pct * circumference).toFixed(1)} ${circumference.toFixed(1)}`;
    }
    get gaugeClass() {
        return `gauge__arc gauge__arc_${(this.patient.riskLevel || 'none').toLowerCase().replace(' ', '-')}`;
    }
    get riskPillClass() {
        return `pill pill_risk-${(this.patient.riskLevel || 'none').toLowerCase().replace(' ', '-')}`;
    }

    // ============================================================ KPI tiles

    get kpis() {
        const p = this.patient;
        const dueIn = daysFromToday(p.nextHbA1cDue);
        const overdueTasks = p.openTasks.filter((t) => t.isOverdue).length;
        let dueText = 'No HbA1c on file';
        let dueTone = 'warn';
        if (dueIn !== null) {
            dueText = dueIn < 0 ? `Overdue by ${-dueIn} days` : `In ${dueIn} days`;
            dueTone = dueIn < 0 ? 'bad' : dueIn <= 30 ? 'warn' : 'good';
        }
        return [
            {
                key: 'a1c',
                label: 'Last HbA1c',
                value: p.lastHbA1cValue !== null && p.lastHbA1cValue !== undefined ? `${p.lastHbA1cValue}%` : '—',
                sub: p.lastHbA1cDate ? formatDate(p.lastHbA1cDate) : 'Not recorded',
                icon: 'utility:heart',
                help: 'Average blood sugar over about 3 months. Goal for most people with diabetes: below 7%.',
                tileClass: `kpi kpi_${this.hba1cTone(p.lastHbA1cValue)}`
            },
            {
                key: 'due',
                label: 'Next HbA1c due',
                value: p.nextHbA1cDue ? formatDate(p.nextHbA1cDue) : '—',
                sub: dueText,
                icon: 'utility:event',
                help: 'Due 180 days after the last test. Overdue = a care gap the nightly job flags.',
                tileClass: `kpi kpi_${dueTone}`
            },
            {
                key: 'prog',
                label: 'Care programs',
                value: String(p.programs.length),
                sub: p.programs.length ? p.programs.map((x) => x.name.replace(' Management Program', '')).join(', ') : 'Not enrolled',
                icon: 'utility:groups',
                help: 'Programs the patient is enrolled in (Care Program Enrollee records).',
                tileClass: 'kpi kpi_neutral'
            },
            {
                key: 'tasks',
                label: 'Open tasks',
                value: String(p.openTasks.length),
                sub: overdueTasks ? `${overdueTasks} overdue` : 'None overdue',
                icon: 'utility:task',
                help: 'Calls, bookings and follow-ups still to do for this patient.',
                tileClass: `kpi kpi_${overdueTasks ? 'bad' : 'neutral'}`
            }
        ];
    }

    /** Example: 8.1 -> 'bad', 7.2 -> 'warn', 6.3 -> 'good' */
    hba1cTone(value) {
        if (value === null || value === undefined) return 'neutral';
        if (value >= HBA1C_HIGH) return 'bad';
        return value >= HBA1C_TARGET ? 'warn' : 'good';
    }

    // ============================================================ HbA1c trend chart (pure SVG)

    get hasHistory() {
        return this.patient.hba1cHistory.length > 0;
    }

    /**
     * Turns the results into SVG coordinates.
     * Y axis: 4% (bottom) to 12% (top), widened if a value falls outside.
     * Example: two results 7.0 and 6.3 -> two dots joined by a line, both below... or around the 7% target line.
     */
    get chart() {
        const rows = this.patient.hba1cHistory;
        const values = rows.map((r) => Number(r.value));
        const min = Math.min(4, ...values);
        const max = Math.max(12, ...values);
        const { width, height, padX, padTop, padBottom } = CHART;
        const plotW = width - padX * 2;
        const plotH = height - padTop - padBottom;
        const x = (i) => (rows.length === 1 ? padX + plotW / 2 : padX + (plotW * i) / (rows.length - 1));
        const y = (v) => padTop + plotH - ((v - min) / (max - min)) * plotH;

        const points = rows.map((r, i) => ({
            key: r.id,
            cx: x(i).toFixed(1),
            cy: y(Number(r.value)).toFixed(1),
            labelY: (y(Number(r.value)) - 9).toFixed(1),
            dateY: (height - 8).toFixed(1),
            value: `${r.value}%`,
            date: formatDate(r.effectiveDate).replace(/ \d{4}$/, ''), // '17 Apr'
            dotClass: `chart__dot chart__dot_${this.hba1cTone(Number(r.value))}`,
            title: `${r.value}% on ${formatDate(r.effectiveDate)}`
        }));
        const targetY = y(HBA1C_TARGET).toFixed(1);
        const line = points.map((p) => `${p.cx},${p.cy}`).join(' ');
        // Area under the line, closed down to the bottom axis, for a soft fill.
        const area = points.length > 1
            ? `${points[0].cx},${padTop + plotH} ${line} ${points[points.length - 1].cx},${padTop + plotH}`
            : '';
        return {
            viewBox: `0 0 ${width} ${height}`,
            points,
            line,
            area,
            targetY,
            targetLabelY: (Number(targetY) - 4).toFixed(1),
            axisY: padTop + plotH,
            axisX2: width - padX
        };
    }

    get trendText() {
        const h = this.patient.hba1cHistory;
        if (h.length < 2) return 'One result so far.';
        const diff = (h[h.length - 1].value - h[h.length - 2].value).toFixed(1);
        if (Number(diff) === 0) return 'Unchanged since the previous test.';
        return Number(diff) < 0 ? `Improved by ${-diff} points since the previous test.` : `Up ${diff} points since the previous test.`;
    }

    // ============================================================ Lists

    get conditions() {
        return this.patient.conditions.map((c) => ({
            ...c,
            statusClass: c.status === 'Active' ? 'pill pill_active' : 'pill',
            sourceLabel: c.source || 'Manual',
            onset: c.onsetDate ? `since ${formatDate(c.onsetDate)}` : ''
        }));
    }
    get programs() {
        return this.patient.programs.map((p) => ({
            ...p,
            statusClass: p.status === 'Active' ? 'pill pill_active' : 'pill',
            enrolled: `Enrolled ${formatDate(p.enrolledOn)}`,
            consentIcon: p.consentSigned ? 'utility:success' : 'utility:warning',
            consentVariant: p.consentSigned ? 'success' : 'warning',
            consentText: p.consentSigned ? 'Program consent signed' : 'Program consent missing',
            contactText: p.contactConsent ? 'Phone/SMS OK' : 'No phone/SMS consent'
        }));
    }
    get barriers() {
        return this.patient.barriers.map((b) => ({
            ...b,
            rowClass: b.isHighPriority ? 'row row_flag' : 'row',
            statusClass: b.status === 'Open' ? 'pill pill_warn' : 'pill'
        }));
    }
    get carePlans() {
        return this.patient.carePlans.map((c) => ({ ...c, statusClass: c.status === 'Active' ? 'pill pill_active' : 'pill' }));
    }
    get openTasks() {
        return this.patient.openTasks.map((t) => {
            const days = daysFromToday(t.dueDate);
            let due = 'No due date';
            if (days !== null) due = days < 0 ? `${-days} days overdue` : days === 0 ? 'Due today' : `Due ${formatDate(t.dueDate)}`;
            return { ...t, due, rowClass: t.isOverdue ? 'row row_overdue' : 'row', icon: t.isHighPriority ? 'utility:priority' : 'utility:task' };
        });
    }

    get hasConditions() { return this.patient.conditions.length > 0; }
    get hasPrograms() { return this.patient.programs.length > 0; }
    get hasBarriers() { return this.patient.barriers.length > 0; }
    get hasCarePlans() { return this.patient.carePlans.length > 0; }
    get hasTasks() { return this.patient.openTasks.length > 0; }

    // ============================================================ Actions

    /** Any row with data-id opens that record. Example: clicking "Food insecurity" opens the CareBarrier. */
    handleOpenRecord(event) {
        const recordId = event.currentTarget.dataset.id;
        if (!recordId) return;
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, actionName: 'view' } });
    }

    /** Keyboard support for rows (Enter or Space), so the card is usable without a mouse. */
    handleRowKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleOpenRecord(event);
        }
    }

    toggleOutreach() {
        this.showOutreach = !this.showOutreach;
        this.outreachNotes = '';
    }

    handleNotesChange(event) {
        this.outreachNotes = event.detail.value;
    }

    /** Saves a completed "Outreach call" task (same Apex as the coordinator dashboard), then refreshes. */
    async handleSaveOutreach() {
        const notes = this.template.querySelector('lightning-textarea');
        if (!notes.reportValidity()) return;
        this.isSaving = true;
        try {
            await logOutreach({ accountId: this.recordId, notes: this.outreachNotes });
            this.toast('Call logged', `Outreach call saved for ${this.patient.name}.`, 'success');
            this.showOutreach = false;
            await refreshApex(this.wiredResult);
        } catch (error) {
            this.toast('Could not log the call', this.reduceError(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    handleRefresh() {
        refreshApex(this.wiredResult);
    }

    // ============================================================ Utilities

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceError(error) {
        if (!error) return 'Unknown error';
        if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(', ');
        if (error.body && error.body.message) return error.body.message;
        return error.message || JSON.stringify(error);
    }
}
