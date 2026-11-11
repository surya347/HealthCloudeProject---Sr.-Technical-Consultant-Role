/**
 * Inbound REST endpoint for the EHR integration.
 *
 *   POST /services/apexrest/fhir/ingest
 *   Body: a FHIR R4 Bundle (application/json)
 *
 *   200 -> everything loaded
 *   207 -> partial success; "errors" lists the records that failed
 *   400 -> the payload couldn't be processed
 *
 * In a real project the caller is MuleSoft (or another middleware) authenticating with an
 * OAuth connected app as a dedicated integration user.
 */
@RestResource(urlMapping='/fhir/ingest')
global with sharing class FhirIngestResource {

    @HttpPost
    global static void ingest() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');
        try {
            String body = RestContext.request.requestBody == null ? null : RestContext.request.requestBody.toString();
            FhirIngestService.IngestResult result = FhirIngestService.ingest(body);
            response.statusCode = result.errors.isEmpty() ? 200 : 207;
            response.responseBody = Blob.valueOf(JSON.serialize(result));
        } catch (Exception e) {
            response.statusCode = 400;
            response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{ 'error' => e.getMessage() }));
        }
    }
}
