/**
 * Patient360Controller
 * ---------------------------------------------------------------------------------------------
 * Apex back end for the patient360 LWC on the patient (person account) record page.
 * ONE cacheable call returns everything the card needs, so the page loads with a single round trip
 * instead of 8 separate related-list queries.
 *
 * What it gathers for one patient:
 *   - Profile + care-management fields   (Account: MRN, risk score, care gap, last HbA1c)
 *   - HbA1c history for the trend chart    (CareObservation, Code.Name = 'Hemoglobin A1c')
 *   - Diagnoses                            (HealthCondition)
 *   - Programs + consent status            (CareProgramEnrollee + AuthorizationFormConsent)
 *   - Care plans                           (CarePlan, ParticipantId = patient)
 *   - Social needs                         (CareBarrier)
 *   - Open tasks                           (Task, WhatId = patient)
 *
 * Best practices: with sharing + WITH USER_MODE (the user only sees what they are allowed to),
 * typed DTOs, small LIMITs on child lists, and no SOQL inside loops.
 *
 * Example LWC use:
 *   @wire(getPatient360, { patientId: '$recordId' }) data;
 */
public with sharing class Patient360Controller {

    @TestVisible static final String HBA1C_NAME = 'Hemoglobin A1c';   // same rule as CareGapBatch
    @TestVisible static final Integer GAP_DAYS = 180;                   // HbA1c older than this = overdue

    // ============================================================ DTOs

    public class Patient360 {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String firstName;
        @AuraEnabled public String mrn;
        @AuraEnabled public Date birthDate;
        @AuraEnabled public Integer age;
        @AuraEnabled public String phone;
        @AuraEnabled public String email;
        @AuraEnabled public String city;
        @AuraEnabled public Decimal riskScore;
        @AuraEnabled public String riskLevel;         // 'High' (70+), 'Medium' (40-69), 'Low', or 'Not scored'
        @AuraEnabled public Boolean careGapOpen;
        @AuraEnabled public Decimal lastHbA1cValue;
        @AuraEnabled public Date lastHbA1cDate;
        @AuraEnabled public Integer daysSinceHbA1c;
        @AuraEnabled public Date nextHbA1cDue;         // last test + 180 days
        @AuraEnabled public List<Observation> hba1cHistory = new List<Observation>();
        @AuraEnabled public List<Condition> conditions = new List<Condition>();
        @AuraEnabled public List<Program> programs = new List<Program>();
        @AuraEnabled public List<Item> carePlans = new List<Item>();
        @AuraEnabled public List<Item> barriers = new List<Item>();
        @AuraEnabled public List<Item> openTasks = new List<Item>();
    }

    /** One HbA1c result. Example: { value: 8.1, effectiveDate: 2026-11-02 } */
    public class Observation {
        @AuraEnabled public Id id;
        @AuraEnabled public Decimal value;
        @AuraEnabled public Date effectiveDate;
    }

    public class Condition {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public Date onsetDate;
        @AuraEnabled public String source;          // 'Epic' or 'Onboarding'
    }

    /** A program membership plus whether program consent is signed. */
    public class Program {
        @AuraEnabled public Id enrolleeId;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public Date enrolledOn;
        @AuraEnabled public Boolean consentSigned = false;
        @AuraEnabled public Boolean contactConsent = false;
    }

    /** Generic row for care plans, barriers and tasks. Example: { title: 'Food insecurity', detail: 'Open · High' } */
    public class Item {
        @AuraEnabled public Id id;
        @AuraEnabled public String title;
        @AuraEnabled public String status;
        @AuraEnabled public String detail;
        @AuraEnabled public Date dueDate;
        @AuraEnabled public Boolean isOverdue = false;
        @AuraEnabled public Boolean isHighPriority = false;
    }

    // ============================================================ Read

    @AuraEnabled(cacheable=true)
    public static Patient360 getPatient360(Id patientId) {
        try {
            List<Account> accounts = [
                SELECT Id, Name, FirstName, IsPersonAccount, Epic_MRN__c, PersonBirthdate,
                       PersonMobilePhone, Phone, PersonEmail, PersonMailingCity,
                       Risk_Score__c, Care_Gap_Open__c, Last_HbA1c_Date__c, Last_HbA1c_Value__c
                FROM Account WHERE Id = :patientId WITH USER_MODE LIMIT 1
            ];
            if (accounts.isEmpty()) {
                throw new AuraHandledException('Patient not found or you do not have access.');
            }
            Account a = accounts[0];
            Patient360 p = new Patient360();
            fillProfile(p, a);
            fillHbA1c(p, patientId);
            fillConditions(p, patientId);
            fillPrograms(p, patientId);
            fillCarePlans(p, patientId);
            fillBarriers(p, patientId);
            fillTasks(p, patientId);
            return p;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            AuraHandledException ex = new AuraHandledException('Could not load Patient 360: ' + e.getMessage());
            ex.setMessage('Could not load Patient 360: ' + e.getMessage());
            throw ex;
        }
    }

    // ============================================================ Sections

    @TestVisible
    private static void fillProfile(Patient360 p, Account a) {
        p.id = a.Id;
        p.name = a.Name;
        p.firstName = a.FirstName;
        p.mrn = a.Epic_MRN__c;
        p.birthDate = a.PersonBirthdate;
        p.age = ageOn(a.PersonBirthdate, Date.today());
        p.phone = String.isNotBlank(a.PersonMobilePhone) ? a.PersonMobilePhone : a.Phone;
        p.email = a.PersonEmail;
        p.city = a.PersonMailingCity;
        p.riskScore = a.Risk_Score__c;
        p.riskLevel = riskLevel(a.Risk_Score__c);
        p.careGapOpen = a.Care_Gap_Open__c == true;
        p.lastHbA1cValue = a.Last_HbA1c_Value__c;
        p.lastHbA1cDate = a.Last_HbA1c_Date__c;
    }

    /** HbA1c history, oldest first (the chart draws left to right). Keeps the last 8 results. */
    private static void fillHbA1c(Patient360 p, Id patientId) {
        String hba1cName = HBA1C_NAME;
        List<CareObservation> rows = [
            SELECT Id, ObservedValueNumerator, EffectiveDateTime
            FROM CareObservation
            WHERE ObservedSubjectId = :patientId AND Code.Name = :hba1cName AND EffectiveDateTime != null
            WITH USER_MODE
            ORDER BY EffectiveDateTime DESC
            LIMIT 8
        ];
        for (Integer i = rows.size() - 1; i >= 0; i--) {
            Observation o = new Observation();
            o.id = rows[i].Id;
            // ObservedValueNumerator can be text or number depending on the org: convert safely.
            o.value = rows[i].ObservedValueNumerator == null
                ? null
                : Decimal.valueOf(String.valueOf(rows[i].ObservedValueNumerator)).setScale(1);
            o.effectiveDate = rows[i].EffectiveDateTime.date();
            p.hba1cHistory.add(o);
        }
        // Fall back to the observations if the nightly job has not filled the Account fields yet.
        if (p.lastHbA1cDate == null && !p.hba1cHistory.isEmpty()) {
            Observation latest = p.hba1cHistory[p.hba1cHistory.size() - 1];
            p.lastHbA1cDate = latest.effectiveDate;
            p.lastHbA1cValue = latest.value;
        }
        if (p.lastHbA1cDate != null) {
            p.daysSinceHbA1c = p.lastHbA1cDate.daysBetween(Date.today());
            p.nextHbA1cDue = p.lastHbA1cDate.addDays(GAP_DAYS);
        }
    }

    private static void fillConditions(Patient360 p, Id patientId) {
        for (HealthCondition hc : [
            SELECT Id, ConditionCode.Name, ConditionStatus, OnsetStartDateTime, SourceSystem
            FROM HealthCondition WHERE PatientId = :patientId
            WITH USER_MODE ORDER BY ConditionStatus, CreatedDate LIMIT 20
        ]) {
            Condition c = new Condition();
            c.id = hc.Id;
            c.name = hc.ConditionCode.Name;
            c.status = hc.ConditionStatus;
            c.onsetDate = hc.OnsetStartDateTime == null ? null : hc.OnsetStartDateTime.date();
            c.source = hc.SourceSystem;
            p.conditions.add(c);
        }
    }

    /** Programs, then ONE consent query for all enrolments (no SOQL in a loop). */
    private static void fillPrograms(Patient360 p, Id patientId) {
        Map<Id, Program> byEnrollee = new Map<Id, Program>();
        for (CareProgramEnrollee e : [
            SELECT Id, Status, CreatedDate, CareProgram.Name
            FROM CareProgramEnrollee WHERE AccountId = :patientId
            WITH USER_MODE ORDER BY CreatedDate LIMIT 20
        ]) {
            Program pr = new Program();
            pr.enrolleeId = e.Id;
            pr.name = e.CareProgram.Name;
            pr.status = e.Status;
            pr.enrolledOn = e.CreatedDate.date();
            byEnrollee.put(e.Id, pr);
        }
        if (!byEnrollee.isEmpty()) {
            Set<Id> enrolleeIds = byEnrollee.keySet();
            for (AuthorizationFormConsent c : [
                SELECT ConsentGiverId, Status, AuthorizationFormText.Name
                FROM AuthorizationFormConsent
                WHERE ConsentGiverId IN :enrolleeIds AND Status = 'Signed'
                WITH USER_MODE
            ]) {
                Program pr = byEnrollee.get(c.ConsentGiverId);
                String textName = c.AuthorizationFormText.Name == null ? '' : c.AuthorizationFormText.Name;
                if (textName.containsIgnoreCase('Contact')) {
                    pr.contactConsent = true;   // e.g. 'Phone and SMS Contact Consent'
                } else {
                    pr.consentSigned = true;    // e.g. 'Care Program Participation Consent'
                }
            }
        }
        p.programs.addAll(byEnrollee.values());
    }

    private static void fillCarePlans(Patient360 p, Id patientId) {
        for (CarePlan cp : [
            SELECT Id, Name, Status, CreatedDate FROM CarePlan
            WHERE ParticipantId = :patientId WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 10
        ]) {
            Item i = new Item();
            i.id = cp.Id;
            i.title = cp.Name;
            i.status = cp.Status;
            i.detail = 'Started ' + cp.CreatedDate.date().format();
            p.carePlans.add(i);
        }
    }

    private static void fillBarriers(Patient360 p, Id patientId) {
        for (CareBarrier b : [
            SELECT Id, Name, Status, Priority, CareBarrierType.Name, Description FROM CareBarrier
            WHERE PatientId = :patientId WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 10
        ]) {
            Item i = new Item();
            i.id = b.Id;
            i.title = b.Name;
            i.status = b.Status;
            i.detail = b.CareBarrierType.Name;
            i.isHighPriority = b.Priority == 'High';
            p.barriers.add(i);
        }
    }

    private static void fillTasks(Patient360 p, Id patientId) {
        for (Task t : [
            SELECT Id, Subject, Status, Priority, ActivityDate FROM Task
            WHERE WhatId = :patientId AND IsClosed = false
            WITH USER_MODE ORDER BY ActivityDate ASC NULLS LAST LIMIT 10
        ]) {
            Item i = new Item();
            i.id = t.Id;
            i.title = t.Subject;
            i.status = t.Status;
            i.dueDate = t.ActivityDate;
            i.isOverdue = t.ActivityDate != null && t.ActivityDate < Date.today();
            i.isHighPriority = t.Priority == 'High';
            p.openTasks.add(i);
        }
    }

    // ============================================================ Small helpers (unit-tested)

    /** Age in whole years. Example: born 1979-03-02, on 2026-11-12 -> 47 */
    @TestVisible
    private static Integer ageOn(Date birthDate, Date onDate) {
        if (birthDate == null) {
            return null;
        }
        Integer age = onDate.year() - birthDate.year();
        if (onDate.month() < birthDate.month() || (onDate.month() == birthDate.month() && onDate.day() < birthDate.day())) {
            age--;
        }
        return age;
    }

    /** Same bands as the dashboard: 70+ High, 40-69 Medium, below 40 Low. */
    @TestVisible
    private static String riskLevel(Decimal score) {
        if (score == null) {
            return 'Not scored';
        }
        if (score >= CareCoordinatorController.HIGH_RISK_THRESHOLD) {
            return 'High';
        }
        return score >= 40 ? 'Medium' : 'Low';
    }
}
