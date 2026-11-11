/**
 * Tests for the patient engagement project: FHIR ingestion (service + REST), care-gap batch,
 * care program enrolment, coordinator dashboard and the Agentforce actions.
 */
@IsTest
private class PatientEngagementTest {

    private static final String MRN_GAP = 'TEST-001';     // diabetic, last HbA1c 300 days ago -> care gap
    private static final String MRN_OK = 'TEST-002';      // diabetic, last HbA1c 30 days ago  -> no gap
    private static final String MRN_HEALTHY = 'TEST-003'; // not diabetic
    private static final Date DOB = Date.newInstance(1980, 5, 20);

    @TestSetup
    static void setup() {
        FhirIngestService.IngestResult result = FhirIngestService.ingest(buildBundle());
        System.assertEquals(0, result.errors.size(), 'Unexpected ingest errors: ' + result.errors);
    }

    // ---------------------------------------------------------------- Ingestion

    @IsTest
    static void ingestCreatesPatientsConditionsAndObservations() {
        System.assertEquals(3, [SELECT COUNT() FROM Account WHERE Epic_MRN__c LIKE 'TEST-%']);
        System.assertEquals(2, [SELECT COUNT() FROM HealthCondition WHERE SourceSystem = 'Epic']);
        System.assertEquals(2, [SELECT COUNT() FROM CareObservation WHERE Name LIKE 'TEST-%']);
        Integration_Log__c log = [SELECT Status__c, Records_Processed__c FROM Integration_Log__c LIMIT 1];
        System.assertEquals('Success', log.Status__c);
        System.assertEquals(7, log.Records_Processed__c);
    }

    @IsTest
    static void ingestIsIdempotent() {
        Test.startTest();
        FhirIngestService.ingest(buildBundle());
        Test.stopTest();
        System.assertEquals(3, [SELECT COUNT() FROM Account WHERE Epic_MRN__c LIKE 'TEST-%'], 'Patients duplicated');
        System.assertEquals(2, [SELECT COUNT() FROM HealthCondition WHERE SourceSystem = 'Epic'], 'Conditions duplicated');
        System.assertEquals(2, [SELECT COUNT() FROM CareObservation WHERE Name LIKE 'TEST-%'], 'Observations duplicated');
    }

    @IsTest
    static void restEndpointReturns200() {
        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf(buildBundle());
        RestContext.response = new RestResponse();
        Test.startTest();
        FhirIngestResource.ingest();
        Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode);
    }

    @IsTest
    static void restEndpointRejectsNonBundle() {
        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf('{"resourceType":"Patient"}');
        RestContext.response = new RestResponse();
        FhirIngestResource.ingest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void parsesFhirDatesAndDateTimes() {
        System.assertEquals(Date.newInstance(2026, 4, 17), FhirIngestService.parseFhirDateTime('2026-04-17').dateGmt());
        System.assertEquals(9, FhirIngestService.parseFhirDateTime('2026-04-17T09:00:00Z').hourGmt());
        System.assertEquals(null, FhirIngestService.parseFhirDateTime(null));
    }

    // ---------------------------------------------------------------- Care gaps

    @IsTest
    static void batchFlagsOnlyOverduePatients() {
        Test.startTest();
        Database.executeBatch(new CareGapBatch(), 200);
        Test.stopTest();

        Account gap = [SELECT Care_Gap_Open__c, Risk_Score__c, Last_HbA1c_Value__c FROM Account WHERE Epic_MRN__c = :MRN_GAP];
        Account ok = [SELECT Care_Gap_Open__c, Risk_Score__c FROM Account WHERE Epic_MRN__c = :MRN_OK];
        Account healthy = [SELECT Risk_Score__c FROM Account WHERE Epic_MRN__c = :MRN_HEALTHY];

        System.assertEquals(true, gap.Care_Gap_Open__c);
        System.assertEquals(80, gap.Risk_Score__c, '30 base + 30 gap + 20 for HbA1c 8.4%');
        System.assertEquals(8.4, gap.Last_HbA1c_Value__c);
        System.assertEquals(false, ok.Care_Gap_Open__c);
        System.assertEquals(null, healthy.Risk_Score__c, 'Non-diabetic patients are not scored');
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE Subject = :CareGapBatch.TASK_SUBJECT]);
    }

    @IsTest
    static void batchDoesNotDuplicateTasks() {
        Test.startTest();
        new CareGapBatch().execute((Database.BatchableContext) null, [SELECT Id, Name, Risk_Score__c, Care_Gap_Open__c FROM Account WHERE Epic_MRN__c = :MRN_GAP]);
        new CareGapBatch().execute((Database.BatchableContext) null, [SELECT Id, Name, Risk_Score__c, Care_Gap_Open__c FROM Account WHERE Epic_MRN__c = :MRN_GAP]);
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE Subject = :CareGapBatch.TASK_SUBJECT]);
    }

    @IsTest
    static void schedulerQueuesBatch() {
        Test.startTest();
        String jobId = System.schedule('Test care gap job', '0 0 2 * * ?', new CareGapBatch());
        Test.stopTest();
        System.assertNotEquals(null, jobId);
    }

    @IsTest
    static void riskScoreIsCapped() {
        System.assertEquals(100, CareGapBatch.calculateRiskScore(true, 9.5, 5));
        System.assertEquals(40, CareGapBatch.calculateRiskScore(false, 7.2, 0));
    }

    // ---------------------------------------------------------------- Care program

    @IsTest
    static void enrollsDiabeticPatientsOnce() {
        Test.startTest();
        Integer first = CareProgramService.enrollDiabeticPatients();
        Integer second = CareProgramService.enrollDiabeticPatients();
        Test.stopTest();
        System.assertEquals(2, first);
        System.assertEquals(0, second);
    }

    // ---------------------------------------------------------------- Dashboard

    @IsTest
    static void dashboardReturnsScoredPatients() {
        new CareGapBatch().execute((Database.BatchableContext) null, [SELECT Id, Name, Risk_Score__c, Care_Gap_Open__c FROM Account WHERE Epic_MRN__c IN (:MRN_GAP, :MRN_OK)]);
        Test.startTest();
        CareCoordinatorController.DashboardData data = CareCoordinatorController.getDashboard();
        Test.stopTest();
        System.assertEquals(2, data.totalPatients);
        System.assertEquals(1, data.openCareGaps);
        System.assertEquals(1, data.highRiskPatients);
        System.assertEquals(MRN_GAP, data.patients[0].mrn, 'Highest risk first');
    }

    @IsTest
    static void logOutreachCreatesCompletedTask() {
        Id patientId = [SELECT Id FROM Account WHERE Epic_MRN__c = :MRN_GAP].Id;
        Test.startTest();
        CareCoordinatorController.logOutreach(patientId, 'Left voicemail');
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhatId = :patientId AND Subject = 'Outreach call' AND IsClosed = true]);
    }

    // ---------------------------------------------------------------- Agent actions

    @IsTest
    static void careGapActionRequiresVerification() {
        new CareGapBatch().execute((Database.BatchableContext) null, [SELECT Id, Name, Risk_Score__c, Care_Gap_Open__c FROM Account WHERE Epic_MRN__c = :MRN_GAP]);

        PatientCareGapAction.Request good = new PatientCareGapAction.Request();
        good.mrn = MRN_GAP;
        good.dateOfBirth = DOB;
        PatientCareGapAction.Request bad = new PatientCareGapAction.Request();
        bad.mrn = MRN_GAP;
        bad.dateOfBirth = DOB.addDays(1);

        List<PatientCareGapAction.Response> res = PatientCareGapAction.getCareGaps(
            new List<PatientCareGapAction.Request>{ good, bad });
        System.assertEquals(true, res[0].verified);
        System.assert(res[0].summary.contains('due for an HbA1c'), res[0].summary);
        System.assertEquals(false, res[1].verified);
    }

    @IsTest
    static void appointmentActionCreatesTask() {
        AppointmentRequestAction.Request req = new AppointmentRequestAction.Request();
        req.mrn = MRN_GAP;
        req.dateOfBirth = DOB;
        req.reason = 'HbA1c lab test';
        req.preferredDate = Date.today().addDays(3);

        List<AppointmentRequestAction.Response> res = AppointmentRequestAction.requestAppointment(
            new List<AppointmentRequestAction.Request>{ req });
        System.assertEquals(true, res[0].success);
        System.assertEquals(1, [SELECT COUNT() FROM Task WHERE Subject = 'Appointment request: HbA1c lab test']);
    }

    // ---------------------------------------------------------------- Test data

    private static String buildBundle() {
        List<Object> entries = new List<Object>{
            patient(MRN_GAP, 'Asha', 'Verma'),
            patient(MRN_OK, 'Ravi', 'Kumar'),
            patient(MRN_HEALTHY, 'Leela', 'Joshi'),
            condition(MRN_GAP),
            condition(MRN_OK),
            hba1c(MRN_GAP, Date.today().addDays(-300), 8.4),
            hba1c(MRN_OK, Date.today().addDays(-30), 6.8)
        };
        return JSON.serialize(new Map<String, Object>{
            'resourceType' => 'Bundle', 'type' => 'transaction', 'entry' => entries
        });
    }

    private static Map<String, Object> patient(String mrn, String firstName, String lastName) {
        return new Map<String, Object>{ 'resource' => new Map<String, Object>{
            'resourceType' => 'Patient',
            'id' => mrn,
            'name' => new List<Object>{ new Map<String, Object>{
                'family' => lastName, 'given' => new List<Object>{ firstName } } },
            'birthDate' => '1980-05-20',
            'address' => new List<Object>{ new Map<String, Object>{ 'city' => 'Pune', 'country' => 'IN' } },
            'telecom' => new List<Object>{ new Map<String, Object>{ 'system' => 'email', 'value' => mrn.toLowerCase() + '@example.com' } }
        } };
    }

    private static Map<String, Object> condition(String mrn) {
        return new Map<String, Object>{ 'resource' => new Map<String, Object>{
            'resourceType' => 'Condition',
            'id' => mrn + '-COND-1',
            'subject' => new Map<String, Object>{ 'reference' => 'Patient/' + mrn },
            'clinicalStatus' => new Map<String, Object>{ 'coding' => new List<Object>{ new Map<String, Object>{ 'code' => 'active' } } },
            'code' => new Map<String, Object>{ 'coding' => new List<Object>{ new Map<String, Object>{
                'system' => 'http://snomed.info/sct', 'code' => '44054006', 'display' => 'Type 2 diabetes mellitus' } } },
            'onsetDateTime' => '2019-03-15'
        } };
    }

    private static Map<String, Object> hba1c(String mrn, Date effective, Decimal value) {
        return new Map<String, Object>{ 'resource' => new Map<String, Object>{
            'resourceType' => 'Observation',
            'id' => mrn + '-A1C-1',
            'status' => 'final',
            'subject' => new Map<String, Object>{ 'reference' => 'Patient/' + mrn },
            'code' => new Map<String, Object>{ 'coding' => new List<Object>{ new Map<String, Object>{
                'system' => 'http://loinc.org', 'code' => '4548-4', 'display' => 'Hemoglobin A1c' } } },
            'effectiveDateTime' => String.valueOf(effective) + 'T09:00:00Z',
            'valueQuantity' => new Map<String, Object>{ 'value' => value, 'unit' => '%' }
        } };
    }
}
