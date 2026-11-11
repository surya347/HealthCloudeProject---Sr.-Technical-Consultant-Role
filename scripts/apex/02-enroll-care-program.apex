// Step 4: create the Diabetes Management Program and enrol every diabetic patient
Integer enrolled = CareProgramService.enrollDiabeticPatients();
System.debug(LoggingLevel.ERROR, 'ENROLLED >>> ' + enrolled);
