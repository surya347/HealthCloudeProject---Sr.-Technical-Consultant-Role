/**
 * Agentforce action: "Request Appointment".
 * Verifies the patient, then creates a Task for the care team to confirm the booking.
 * (A full build would call Intelligent Appointment Management or a scheduling API here.)
 */
public with sharing class AppointmentRequestAction {

    public class Request {
        @InvocableVariable(label='Patient MRN' required=true)
        public String mrn;
        @InvocableVariable(label='Date of Birth' required=true)
        public Date dateOfBirth;
        @InvocableVariable(label='Reason for Visit' description='For example: HbA1c lab test, diabetes review' required=true)
        public String reason;
        @InvocableVariable(label='Preferred Date' description='The date the patient would like, if they gave one')
        public Date preferredDate;
    }

    public class Response {
        @InvocableVariable(label='Success')
        public Boolean success;
        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Request Appointment'
        description='Verifies the patient with MRN and date of birth and sends an appointment request to the care team.'
        category='Patient Intake'
    )
    public static List<Response> requestAppointment(List<Request> requests) {
        List<Response> responses = new List<Response>();
        List<Task> tasks = new List<Task>();
        for (Request req : requests) {
            Response res = new Response();
            Account patient = PatientSupport.verifyPatient(req.mrn, req.dateOfBirth);
            if (patient == null) {
                res.success = false;
                res.message = 'I could not verify the patient with the details provided, so no request was made.';
            } else {
                Date wanted = (req.preferredDate != null && req.preferredDate >= Date.today())
                    ? req.preferredDate : Date.today().addDays(1);
                tasks.add(new Task(
                    WhatId = patient.Id,
                    Subject = ('Appointment request: ' + req.reason).left(255),
                    Status = 'Not Started',
                    Priority = 'Normal',
                    ActivityDate = wanted,
                    Description = 'Requested via Patient Intake Agent. Preferred date: ' + wanted.format()
                ));
                res.success = true;
                res.message = 'Your request for "' + req.reason + '" has been sent to the care team for '
                    + wanted.format() + '. They will contact you to confirm the time.';
            }
            responses.add(res);
        }
        insert tasks;
        return responses;
    }
}
