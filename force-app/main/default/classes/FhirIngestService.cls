/**
 * Loads a FHIR R4 Bundle from the EHR (Epic) into the Health Cloud clinical data model.
 *
 *   Patient     -> Account (person account), upserted on Epic_MRN__c
 *   Condition   -> HealthCondition, matched on SourceSystem + SourceSystemIdentifier
 *   Observation -> CareObservation, matched on Name (= FHIR resource id)
 *
 * Idempotent: posting the same bundle twice updates records instead of duplicating them.
 * Partial success: a bad record is reported in the result and the Integration Log; the rest still load.
 */
public with sharing class FhirIngestService {

    public class IngestException extends Exception {}

    public static final String SOURCE_SYSTEM = 'Epic';

    public class IngestResult {
        public Integer patients = 0;
        public Integer conditions = 0;
        public Integer observations = 0;
        public List<String> errors = new List<String>();
        public Integer total() {
            return patients + conditions + observations;
        }
    }

    /** Convenience entry point for the demo: loads the bundle stored as a static resource. */
    public static IngestResult ingestStaticResource(String resourceName) {
        StaticResource sr = [SELECT Body FROM StaticResource WHERE Name = :resourceName LIMIT 1];
        return ingest(sr.Body.toString());
    }

    public static IngestResult ingest(String bundleJson) {
        if (String.isBlank(bundleJson)) {
            throw new IngestException('Empty request body.');
        }
        Map<String, Object> bundle = (Map<String, Object>) JSON.deserializeUntyped(bundleJson);
        if ((String) bundle.get('resourceType') != 'Bundle') {
            throw new IngestException('Payload is not a FHIR Bundle.');
        }

        List<Map<String, Object>> patients = new List<Map<String, Object>>();
        List<Map<String, Object>> conditions = new List<Map<String, Object>>();
        List<Map<String, Object>> observations = new List<Map<String, Object>>();
        List<Object> entries = (List<Object>) bundle.get('entry');
        if (entries != null) {
            for (Object entryObj : entries) {
                Map<String, Object> resource = (Map<String, Object>) ((Map<String, Object>) entryObj).get('resource');
                if (resource == null) {
                    continue;
                }
                String resourceType = (String) resource.get('resourceType');
                if (resourceType == 'Patient') {
                    patients.add(resource);
                } else if (resourceType == 'Condition') {
                    conditions.add(resource);
                } else if (resourceType == 'Observation') {
                    observations.add(resource);
                }
            }
        }

        IngestResult result = new IngestResult();
        Map<String, Id> accountIdByMrn = upsertPatients(patients, result);
        upsertConditions(conditions, accountIdByMrn, result);
        upsertObservations(observations, accountIdByMrn, result);
        logResult(result);
        return result;
    }

    // ---------------------------------------------------------------- Patients

    private static Map<String, Id> upsertPatients(List<Map<String, Object>> resources, IngestResult result) {
        Id patientRecordTypeId = PatientSupport.patientRecordTypeId();
        List<Account> accounts = new List<Account>();
        for (Map<String, Object> p : resources) {
            Account a = new Account(RecordTypeId = patientRecordTypeId, Epic_MRN__c = (String) p.get('id'));
            List<Object> names = (List<Object>) p.get('name');
            if (names != null && !names.isEmpty()) {
                Map<String, Object> name = (Map<String, Object>) names[0];
                List<Object> given = (List<Object>) name.get('given');
                a.FirstName = (given != null && !given.isEmpty()) ? (String) given[0] : null;
                a.LastName = (String) name.get('family');
            }
            if (String.isBlank(a.LastName)) {
                a.LastName = 'Unknown';
            }
            if (p.get('birthDate') != null) {
                a.PersonBirthdate = Date.valueOf((String) p.get('birthDate'));
            }
            List<Object> telecoms = (List<Object>) p.get('telecom');
            if (telecoms != null) {
                for (Object t : telecoms) {
                    Map<String, Object> telecom = (Map<String, Object>) t;
                    if (telecom.get('system') == 'phone') {
                        a.PersonMobilePhone = (String) telecom.get('value');
                    } else if (telecom.get('system') == 'email') {
                        a.PersonEmail = (String) telecom.get('value');
                    }
                }
            }
            List<Object> addresses = (List<Object>) p.get('address');
            if (addresses != null && !addresses.isEmpty()) {
                Map<String, Object> address = (Map<String, Object>) addresses[0];
                a.PersonMailingCity = (String) address.get('city');
                setCountry(a, (String) address.get('country'));
            }
            accounts.add(a);
        }

        Map<String, Id> accountIdByMrn = new Map<String, Id>();
        List<Database.UpsertResult> saveResults = Database.upsert(accounts, Account.Epic_MRN__c, false);
        for (Integer i = 0; i < saveResults.size(); i++) {
            if (saveResults[i].isSuccess()) {
                accountIdByMrn.put(accounts[i].Epic_MRN__c, saveResults[i].getId());
                result.patients++;
            } else {
                result.errors.add('Patient ' + accounts[i].Epic_MRN__c + ': ' + firstError(saveResults[i].getErrors()));
            }
        }
        return accountIdByMrn;
    }

    // ---------------------------------------------------------------- Conditions

    private static void upsertConditions(List<Map<String, Object>> resources, Map<String, Id> accountIdByMrn, IngestResult result) {
        Set<String> fhirIds = new Set<String>();
        for (Map<String, Object> c : resources) {
            fhirIds.add((String) c.get('id'));
        }
        Map<String, Id> existingIdByFhirId = new Map<String, Id>();
        for (HealthCondition hc : [
            SELECT Id, SourceSystemIdentifier FROM HealthCondition
            WHERE SourceSystem = :SOURCE_SYSTEM AND SourceSystemIdentifier IN :fhirIds
        ]) {
            existingIdByFhirId.put(hc.SourceSystemIdentifier, hc.Id);
        }

        List<HealthCondition> toInsert = new List<HealthCondition>();
        List<HealthCondition> toUpdate = new List<HealthCondition>();
        for (Map<String, Object> c : resources) {
            String fhirId = (String) c.get('id');
            Id patientId = accountIdByMrn.get(referenceId(c.get('subject')));
            if (patientId == null) {
                result.errors.add('Condition ' + fhirId + ': patient not found in this bundle.');
                continue;
            }
            Map<String, Object> coding = firstCoding(c.get('code'));
            if (coding == null) {
                result.errors.add('Condition ' + fhirId + ': missing code.');
                continue;
            }
            HealthCondition hc = new HealthCondition(
                ConditionCodeId = CodeSetService.resolveFor(
                    HealthCondition.ConditionCodeId, (String) coding.get('code'), (String) coding.get('display')),
                ConditionStatus = capitalize((String) firstCodingValue(c.get('clinicalStatus'))),
                OnsetStartDateTime = parseFhirDateTime((String) c.get('onsetDateTime')),
                SourceSystem = SOURCE_SYSTEM,
                SourceSystemIdentifier = fhirId
            );
            if (existingIdByFhirId.containsKey(fhirId)) {
                hc.Id = existingIdByFhirId.get(fhirId);
                toUpdate.add(hc);
            } else {
                hc.PatientId = patientId;
                toInsert.add(hc);
            }
        }
        result.conditions += countSaved(Database.insert(toInsert, false), 'Condition', result);
        result.conditions += countSaved(Database.update(toUpdate, false), 'Condition', result);
    }

    // ---------------------------------------------------------------- Observations

    private static void upsertObservations(List<Map<String, Object>> resources, Map<String, Id> accountIdByMrn, IngestResult result) {
        Set<String> fhirIds = new Set<String>();
        for (Map<String, Object> o : resources) {
            fhirIds.add((String) o.get('id'));
        }
        Map<String, Id> existingIdByFhirId = new Map<String, Id>();
        for (CareObservation co : [SELECT Id, Name FROM CareObservation WHERE Name IN :fhirIds]) {
            existingIdByFhirId.put(co.Name, co.Id);
        }

        List<CareObservation> toInsert = new List<CareObservation>();
        List<CareObservation> toUpdate = new List<CareObservation>();
        for (Map<String, Object> o : resources) {
            String fhirId = (String) o.get('id');
            Id patientId = accountIdByMrn.get(referenceId(o.get('subject')));
            Map<String, Object> coding = firstCoding(o.get('code'));
            Map<String, Object> quantity = (Map<String, Object>) o.get('valueQuantity');
            if (patientId == null || coding == null || quantity == null) {
                result.errors.add('Observation ' + fhirId + ': missing patient, code or numeric value.');
                continue;
            }
            CareObservation co = new CareObservation(
                Name = fhirId,
                CodeId = CodeSetService.resolveFor(
                    CareObservation.CodeId, (String) coding.get('code'), (String) coding.get('display')),
                ObservationStatus = capitalize((String) o.get('status')),
                EffectiveDateTime = parseFhirDateTime((String) o.get('effectiveDateTime')),
                ObservedValueType = 'Quantity',
                ObservedValueNumerator = Decimal.valueOf(String.valueOf(quantity.get('value'))),
                ObservedValueUnitId = unitOfMeasureId((String) quantity.get('unit'))
            );
            if (existingIdByFhirId.containsKey(fhirId)) {
                co.Id = existingIdByFhirId.get(fhirId);
                toUpdate.add(co);
            } else {
                co.ObservedSubjectId = patientId;
                toInsert.add(co);
            }
        }
        result.observations += countSaved(Database.insert(toInsert, false), 'Observation', result);
        result.observations += countSaved(Database.update(toUpdate, false), 'Observation', result);
    }

    // ---------------------------------------------------------------- Logging

    private static void logResult(IngestResult result) {
        String status = result.errors.isEmpty() ? 'Success' : (result.total() > 0 ? 'Partial' : 'Failed');
        String message = 'Patients: ' + result.patients + ', Conditions: ' + result.conditions
            + ', Observations: ' + result.observations;
        if (!result.errors.isEmpty()) {
            message += '\nErrors:\n' + String.join(result.errors, '\n');
        }
        insert new Integration_Log__c(
            Source__c = 'Epic FHIR',
            Status__c = status,
            Records_Processed__c = result.total(),
            Message__c = message.left(32000)
        );
    }

    // ---------------------------------------------------------------- Helpers

    /**
     * FHIR sends an ISO country code such as "IN". Orgs with State and Country picklists turned on
     * only accept it in PersonMailingCountryCode; orgs without them take it in PersonMailingCountry.
     */
    private static void setCountry(Account a, String isoCode) {
        if (String.isBlank(isoCode)) {
            return;
        }
        if (Schema.SObjectType.Account.fields.getMap().containsKey('personmailingcountrycode')) {
            a.put('PersonMailingCountryCode', isoCode.toUpperCase());
        } else {
            a.put('PersonMailingCountry', isoCode);
        }
    }

    private static Map<String, Id> unitIdByCode = new Map<String, Id>();

    /** Health Cloud requires a unit on numeric observations; finds or creates it (e.g. "%"). */
    public static Id unitOfMeasureId(String unitCode) {
        String code = String.isBlank(unitCode) ? '1' : unitCode;
        if (unitIdByCode.containsKey(code)) {
            return unitIdByCode.get(code);
        }
        List<UnitOfMeasure> existing = [SELECT Id FROM UnitOfMeasure WHERE UnitCode = :code LIMIT 1];
        Id unitId;
        if (existing.isEmpty()) {
            UnitOfMeasure u = new UnitOfMeasure(
                Name = (code == '%') ? 'Percent' : code,
                UnitCode = code,
                Type = 'Custom',
                Status = 'Active'
            );
            insert u;
            unitId = u.Id;
        } else {
            unitId = existing[0].Id;
        }
        unitIdByCode.put(code, unitId);
        return unitId;
    }

    private static Integer countSaved(List<Database.SaveResult> saveResults, String label, IngestResult result) {
        Integer saved = 0;
        for (Database.SaveResult sr : saveResults) {
            if (sr.isSuccess()) {
                saved++;
            } else {
                result.errors.add(label + ': ' + firstError(sr.getErrors()));
            }
        }
        return saved;
    }

    private static String firstError(List<Database.Error> errors) {
        return errors.isEmpty() ? 'Unknown error' : errors[0].getMessage();
    }

    /** "Patient/EPIC-100001" -> "EPIC-100001" */
    private static String referenceId(Object reference) {
        if (reference == null) {
            return null;
        }
        String ref = (String) ((Map<String, Object>) reference).get('reference');
        return ref == null ? null : ref.substringAfter('/');
    }

    private static Map<String, Object> firstCoding(Object codeableConcept) {
        if (codeableConcept == null) {
            return null;
        }
        List<Object> codings = (List<Object>) ((Map<String, Object>) codeableConcept).get('coding');
        return (codings == null || codings.isEmpty()) ? null : (Map<String, Object>) codings[0];
    }

    private static Object firstCodingValue(Object codeableConcept) {
        Map<String, Object> coding = firstCoding(codeableConcept);
        return coding == null ? null : coding.get('code');
    }

    private static String capitalize(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.substring(0, 1).toUpperCase() + value.substring(1).toLowerCase();
    }

    /** Accepts FHIR date ("2026-04-17") or dateTime ("2026-04-17T09:00:00Z"). */
    @TestVisible
    private static Datetime parseFhirDateTime(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        if (value.length() == 10) {
            return Datetime.newInstanceGmt(Date.valueOf(value), Time.newInstance(0, 0, 0, 0));
        }
        return (Datetime) JSON.deserialize('"' + value + '"', Datetime.class);
    }
}
