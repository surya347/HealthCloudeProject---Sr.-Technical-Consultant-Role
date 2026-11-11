// Step 4 + 6: Type 2 Diabetes care plan template, a care coordination case and care plan for Aarav,
// four care plan tasks, and a transportation care barrier (SDOH). Runs as one transaction.
Account p = [SELECT Id, PersonContactId FROM Account WHERE Epic_MRN__c = 'EPIC-100001' LIMIT 1];
List<CareBarrierType> transport = [SELECT Id FROM CareBarrierType WHERE Name LIKE '%Transportation%' LIMIT 1];

CarePlanTemplate t = new CarePlanTemplate(Name = 'Type 2 Diabetes Care Plan', Status = 'Published',
    Description = 'Problem: uncontrolled blood glucose. Goal: HbA1c below 7% within 6 months. '
        + 'Tasks: HbA1c lab test every 6 months; medication review; diet and exercise coaching; annual eye and foot exam.');
insert t;

// In Health Cloud a care plan belongs to the patient's care coordination case (CarePlan.CaseId is master-detail)
Case c = new Case(Subject = 'Care coordination: Aarav Nair', AccountId = p.Id, ContactId = p.PersonContactId, Status = 'New');
insert c;

CarePlan cp = new CarePlan(Name = 'Type 2 Diabetes Care Plan for Aarav Nair', CaseId = c.Id, ParticipantId = p.Id,
    CarePlanTemplateId = t.Id, Status = 'Active',
    Description = 'Problem: uncontrolled blood glucose (type 2 diabetes). Goal: HbA1c below 7% within 6 months.');
insert cp;

insert new List<Task>{
    new Task(WhatId = cp.Id, Subject = 'HbA1c lab test (every 6 months)', Priority = 'High', Status = 'Not Started', ActivityDate = Date.today().addDays(7)),
    new Task(WhatId = cp.Id, Subject = 'Medication review with physician', Priority = 'Normal', Status = 'Not Started', ActivityDate = Date.today().addDays(30)),
    new Task(WhatId = cp.Id, Subject = 'Diet and exercise coaching', Priority = 'Normal', Status = 'Not Started', ActivityDate = Date.today().addDays(14)),
    new Task(WhatId = cp.Id, Subject = 'Annual eye and foot exam', Priority = 'Normal', Status = 'Not Started', ActivityDate = Date.today().addDays(60))
};

insert new CareBarrier(Name = 'Lack of access to Transportation', PatientId = p.Id,
    CareBarrierTypeId = transport.isEmpty() ? null : transport[0].Id,
    Status = 'Open', Priority = 'High', IsActive = true, EffectiveFrom = Date.today(),
    Description = 'No transport to the lab for HbA1c tests; relies on family. Arrange transport when booking.');
