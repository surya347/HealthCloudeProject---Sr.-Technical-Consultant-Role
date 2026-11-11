// Step 5: run the care-gap job now (check Setup > Apex Jobs for completion)
Id jobId = Database.executeBatch(new CareGapBatch(), 200);
System.debug(LoggingLevel.ERROR, 'BATCH JOB >>> ' + jobId);
