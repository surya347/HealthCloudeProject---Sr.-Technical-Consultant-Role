/**
 * Agentforce action: "Get Patient Care Gaps".
 * The agent must collect the patient's MRN and date of birth; both must match before anything is returned.
 */
public with sharing class PatientCareGapAction {

    public class Request {
        @InvocableVariable(label='Patient MRN' description='The patient\'s medical record number, e.g. EPIC-100001' required=true)
        public String mrn;
        @InvocableVariable(label='Date of Birth' description='The patient\'s date of birth, used to verify identity' required=true)
        public Date dateOfBirth;
    }

    public class Response {
        @InvocableVariable(label='Verified' description='True when the MRN and date of birth matched a patient')
        public Boolean verified;
        @InvocableVariable(label='Care Gap Summary' description='Plain-language summary of tests the patient is due for')
        public String summary;
    }

    @InvocableMethod(
        label='Get Patient Care Gaps'
        description='Verifies the patient with MRN and date of birth, then returns which preventive tests (such as HbA1c) are overdue and when the last test was done.'
        category='Patient Intake'
    )
    public static List<Response> getCareGaps(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            Account patient = PatientSupport.verifyPatient(req.mrn, req.dateOfBirth);
            if (patient == null) {
                res.verified = false;
                res.summary = 'I could not verify the patient with the details provided. Please check the MRN and date of birth.';
            } else {
                res.verified = true;
                res.summary = buildSummary(patient);
            }
            responses.add(res);
        }
        return responses;
    }

    private static String buildSummary(Account patient) {
        String firstName = String.isBlank(patient.FirstName) ? 'The patient' : patient.FirstName;
        if (patient.Risk_Score__c == null) {
            return firstName + ' has no tracked care gaps at the moment.';
        }
        String lastTest = patient.Last_HbA1c_Date__c == null
            ? 'There is no HbA1c result on file.'
            : 'The last HbA1c test was on ' + patient.Last_HbA1c_Date__c.format() + '.';
        if (patient.Care_Gap_Open__c) {
            return firstName + ' is due for an HbA1c blood test. ' + lastTest
                + ' I can request an appointment with the care team to book it.';
        }
        return firstName + ' is up to date with HbA1c testing. ' + lastTest;
    }
}
