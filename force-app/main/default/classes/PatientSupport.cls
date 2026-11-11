/**
 * Shared helpers for working with patients (person accounts) in Health Cloud.
 */
public with sharing class PatientSupport {

    public class PatientSupportException extends Exception {}

    private static Id cachedPatientRecordTypeId;

    /**
     * Returns the person-account record type used for patients.
     * Prefers a record type whose name contains "Patient"; otherwise the first active person-account type.
     */
    public static Id patientRecordTypeId() {
        if (cachedPatientRecordTypeId != null) {
            return cachedPatientRecordTypeId;
        }
        List<RecordType> personTypes = [
            SELECT Id, Name, DeveloperName
            FROM RecordType
            WHERE SobjectType = 'Account' AND IsPersonType = true AND IsActive = true
            ORDER BY Name
        ];
        if (personTypes.isEmpty()) {
            throw new PatientSupportException('Person Accounts are not enabled in this org.');
        }
        cachedPatientRecordTypeId = personTypes[0].Id;
        for (RecordType rt : personTypes) {
            if (rt.Name.containsIgnoreCase('patient') || rt.DeveloperName.containsIgnoreCase('patient')) {
                cachedPatientRecordTypeId = rt.Id;
                break;
            }
        }
        return cachedPatientRecordTypeId;
    }

    /**
     * Two-factor identity check used by the agent actions: the MRN and the date of birth must both match.
     * Returns null when the patient can't be verified, so callers never reveal whether an MRN exists.
     */
    public static Account verifyPatient(String mrn, Date dateOfBirth) {
        if (String.isBlank(mrn) || dateOfBirth == null) {
            return null;
        }
        List<Account> matches = [
            SELECT Id, Name, FirstName, PersonBirthdate, Risk_Score__c, Care_Gap_Open__c,
                   Last_HbA1c_Date__c, Last_HbA1c_Value__c
            FROM Account
            WHERE Epic_MRN__c = :mrn.trim() AND PersonBirthdate = :dateOfBirth
            LIMIT 1
        ];
        return matches.isEmpty() ? null : matches[0];
    }
}
