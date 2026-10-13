// Adds one Northwind meeting whose notes size Project Keel differently from CRM, so the summary has a genuine
// notes-vs-CRM conflict to report (the "conflicts" section). CRM: Project Keel - Acquisition of Baltic Ferry Lines,
// USD 850,000,000. Notes: ~$1.1bn.
//
// Insert only: no existing record is read for update or changed. Safe to re-run: skips if the meeting already exists.
// Run: sf apex run -o banking -f scripts/apex/add-conflict-meeting.apex

final String ACCOUNT_NAME = 'Northwind Maritime Group';
final Date MEETING_DATE = Date.newInstance(2026, 10, 9);
final String MARKER = 'Keel now sized at ~$1.1bn';

List<Account> accounts = [SELECT Id FROM Account WHERE Name = :ACCOUNT_NAME LIMIT 1];
if (accounts.isEmpty()) {
    throw new IllegalArgumentException('Account not found: ' + ACCOUNT_NAME + '. Run seed-data.apex first.');
}
Id accountId = accounts[0].Id;

for (Client_Meeting__c existing : [SELECT Name, Meeting_Notes__c FROM Client_Meeting__c
                                   WHERE Account__c = :accountId AND Meeting_Date__c = :MEETING_DATE]) {
    if (existing.Meeting_Notes__c != null && existing.Meeting_Notes__c.contains(MARKER)) {
        System.debug(LoggingLevel.ERROR, 'CONFLICT MEETING ALREADY EXISTS: ' + existing.Name);
        return;
    }
}

Client_Meeting__c m = new Client_Meeting__c(
    Account__c = accountId,
    Meeting_Date__c = MEETING_DATE,
    Attendees__c = 'Henrik Aalto (CEO), Sofia Mendes (CFO), M&A team',
    Meeting_Notes__c = 'Keel check-in. HA says the other family branch is now in, so it\'s the whole company not one branch. '
        + MARKER + ' incl. the second branch. SM fine on funding if leverage stays < 3x.\n'
        + 'diligence: vessel surveys back next wk, no surprises so far.\n'
        + 'next: we refresh valuation pages for the full perimeter, JW to confirm timing with the family advisers.'
);
insert m;
System.debug(LoggingLevel.ERROR, 'CREATED CONFLICT MEETING: ' + [SELECT Name FROM Client_Meeting__c WHERE Id = :m.Id].Name);
