// Step 2-3: load the mock Epic FHIR bundle (stored as the EpicSampleBundle static resource)
FhirIngestService.IngestResult r = FhirIngestService.ingestStaticResource('EpicSampleBundle');
System.debug(LoggingLevel.ERROR, 'INGEST RESULT >>> ' + JSON.serializePretty(r));
