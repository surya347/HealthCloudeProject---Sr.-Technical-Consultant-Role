// Step 5: schedule the care-gap job nightly at 2 AM (org time zone)
String jobId = System.schedule('Nightly care gap check', '0 0 2 * * ?', new CareGapBatch());
System.debug(LoggingLevel.ERROR, 'SCHEDULED >>> ' + jobId);
