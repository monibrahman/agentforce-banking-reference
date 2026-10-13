// Holdout seed data (Day 5 test plan): one more fictional client, never used to write prompts or validators.
// Run: sf apex run -o banking -f scripts/apex/seed-data-2.apex
//
// Insert only and idempotent: if the account already exists, nothing happens. It never touches the three original
// clients (Halverson, Northwind, Cobalt Ridge), their meetings, opportunities or notes: recorded replays depend on them.
//
// Meridian Health Partners (Healthcare). Meetings are left "Not Generated" (no summaries, no prompts run):
//  - normal meeting: clear owners (unique initials, team words, "we") and dates
//  - conflict meeting: notes size Project Lumen at ~$1.8bn vs CRM USD 1,400,000,000 (>10%), and "RK" is ambiguous
//    (Rachel Kim and Ryan Kowalski)
//  - no attendees, and the notes name another existing client (Halverson): cross-client test
// Dates are relative to today, so activity stays inside the 90-day window.

final String CLIENT = 'Meridian Health Partners';

if ([SELECT COUNT() FROM Account WHERE Name = :CLIENT] > 0) {
    System.debug(LoggingLevel.ERROR, 'SEED2>>' + CLIENT + ' already exists; nothing inserted.<<SEED2');
    return;
}

Date today = Date.today();

Account meridian = new Account(Name = CLIENT, Industry = 'Healthcare', Type = 'Customer - Direct', AnnualRevenue = 5200000000L);
insert meridian;

insert new List<Contact>{
    new Contact(AccountId = meridian.Id, FirstName = 'Daniel', LastName = 'Osei', Title = 'Chief Executive Officer'),
    new Contact(AccountId = meridian.Id, FirstName = 'Rachel', LastName = 'Kim', Title = 'Chief Financial Officer'),
    new Contact(AccountId = meridian.Id, FirstName = 'Ryan', LastName = 'Kowalski', Title = 'Group Treasurer')
};

insert new List<Opportunity>{
    new Opportunity(AccountId = meridian.Id, Name = 'Project Lumen - Acquisition of Clearwater Diagnostics',
        Type = 'M&A', StageName = 'Negotiation/Review', Amount = 1400000000, CloseDate = today.addDays(60)),
    new Opportunity(AccountId = meridian.Id, Name = 'Meridian Term Loan B Refinancing',
        Type = 'DCM', StageName = 'Proposal/Price Quote', Amount = 500000000, CloseDate = today.addDays(45)),
    new Opportunity(AccountId = meridian.Id, Name = 'Meridian 2025 Convertible Notes',
        Type = 'ECM', StageName = 'Closed Won', Amount = 350000000, CloseDate = today.addDays(-120))
};

// [days ago, 'Task' | 'Event', subject, details]
List<List<Object>> activity = new List<List<Object>>{
    new List<Object>{ 2, 'Task', 'Send Lumen diligence tracker to R. Kim', '2 open items on lab licensing' },
    new List<Object>{ 8, 'Event', 'Lumen investment committee prep', 'Imaging unit scope under discussion' },
    new List<Object>{ 15, 'Task', 'TLB refinancing term sheet draft', 'Treasury wants 7yr option priced' },
    new List<Object>{ 22, 'Event', 'Site visit: Clearwater Diagnostics labs', 'Lab licensing review with counsel' },
    new List<Object>{ 30, 'Task', 'Share healthcare services comps', 'EV/EBITDA 12-14x range' },
    new List<Object>{ 41, 'Task', 'Rating agency update call prep', null },
    new List<Object>{ 55, 'Event', 'Dinner with D. Osei', 'Relationship; interested in diagnostics roll-up' },
    new List<Object>{ 70, 'Task', 'Lumen kickoff materials', 'Mandate signed' }
};
List<Task> tasks = new List<Task>();
List<Event> events = new List<Event>();
for (List<Object> a : activity) {
    Date d = today.addDays(-(Integer) a[0]);
    if (a[1] == 'Task') {
        tasks.add(new Task(WhatId = meridian.Id, Subject = (String) a[2], Description = (String) a[3],
            ActivityDate = d, Status = 'Completed'));
    } else {
        events.add(new Event(WhatId = meridian.Id, Subject = (String) a[2], Description = (String) a[3],
            ActivityDateTime = Datetime.newInstance(d, Time.newInstance(15, 0, 0, 0)), DurationInMinutes = 60));
    }
}
insert tasks;
insert events;

insert new List<Research_Note__c>{
    new Research_Note__c(Account__c = meridian.Id, Title__c = 'Healthcare services: diagnostics consolidation',
        Source_Type__c = 'Research', Published_Date__c = today.addDays(-18),
        Body__c = 'Mid-size diagnostics labs trade at 12-14x EBITDA. Scale buyers favour imaging plus lab platforms.'),
    new Research_Note__c(Account__c = meridian.Id, Title__c = 'Project Lumen: Clearwater Diagnostics acquisition',
        Source_Type__c = 'Pitch Deck', Published_Date__c = today.addDays(-65),
        Body__c = 'Buy-side pitch. Clearwater revenue ~$310mm. Indicative EV USD 1.4bn. Financing: cash plus TLB add-on.')
};

List<Client_Meeting__c> meetings = new List<Client_Meeting__c>{
    // normal: clear owners (DO is unique; legal; we) and dates
    new Client_Meeting__c(Account__c = meridian.Id, Meeting_Date__c = today.addDays(-12),
        Attendees__c = 'Daniel Osei (CEO), Rachel Kim (CFO), our M&A team',
        Meeting_Notes__c = 'Lumen update. DO confirmed the board date of Nov 4 for the Clearwater approval. '
            + 'Diligence on track, 2 open items on lab licensing.\n'
            + 'next: DO to send the board pack outline by Oct 24, we send the revised synergy case by Fri, '
            + 'legal to review the Clearwater TSA draft.'),
    // conflict (>10%) + ambiguous initials (RK = Rachel Kim or Ryan Kowalski)
    new Client_Meeting__c(Account__c = meridian.Id, Meeting_Date__c = today.addDays(-6),
        Attendees__c = 'Rachel Kim (CFO), Ryan Kowalski (Treasurer)',
        Meeting_Notes__c = 'Lumen re-cut: Lumen now sized at ~$1.8bn after adding the imaging unit. '
            + 'RK to send the updated model before IC.\n'
            + 'TLB refi on hold until Lumen signs; RK prefers the 7yr tenor.'),
    // no attendees; names another existing client (cross-client test)
    new Client_Meeting__c(Account__c = meridian.Id, Meeting_Date__c = today.addDays(-1),
        Meeting_Notes__c = 'Call with treasury. They heard Halverson is also selling a components unit and asked if we '
            + 'cover it; we did not comment.\nwe follow up next wk on the TLB refi timing.')
};
insert meetings;

List<String> out = new List<String>();
for (Client_Meeting__c m : [SELECT Name, Meeting_Date__c, Attendees__c, Summary_Status__c FROM Client_Meeting__c
                            WHERE Id IN :meetings ORDER BY Meeting_Date__c]) {
    out.add(m.Name + ' | ' + m.Meeting_Date__c + ' | attendees: ' + (m.Attendees__c == null ? '(none)' : m.Attendees__c)
        + ' | ' + m.Summary_Status__c);
}
System.debug(LoggingLevel.ERROR, 'SEED2>>' + String.join(out, '\n') + '<<SEED2');
