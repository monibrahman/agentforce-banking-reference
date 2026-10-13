@IsTest
private class FindClientMeetingsActionTest {

    @TestSetup
    static void setup() {
        SummaryTestData.createAll();   // 6 client accounts, one meeting each on 2026-09-20
    }

    static FindClientMeetingsAction.Response find(String accountName, Date dateFrom, Date dateTo, String meetingName) {
        return find(accountName, dateFrom, dateTo, meetingName, null);
    }

    static FindClientMeetingsAction.Response find(String accountName, Date dateFrom, Date dateTo, String meetingName, String attendeeName) {
        FindClientMeetingsAction.Request req = new FindClientMeetingsAction.Request();
        req.accountName = accountName;
        req.dateFrom = dateFrom;
        req.dateTo = dateTo;
        req.meetingName = meetingName;
        req.attendeeName = attendeeName;
        return FindClientMeetingsAction.find(new List<FindClientMeetingsAction.Request>{ req })[0];
    }

    /** Extra Halverson meetings on the given dates. */
    static void addHalversonMeetings(List<Date> dates) {
        Id accountId = [SELECT Id FROM Account WHERE Name = :SummaryTestData.HALVERSON].Id;
        List<Client_Meeting__c> rows = new List<Client_Meeting__c>();
        for (Date d : dates) {
            rows.add(new Client_Meeting__c(Account__c = accountId, Meeting_Date__c = d, Meeting_Notes__c = 'Extra meeting notes'));
        }
        insert rows;
    }

    @IsTest
    static void partialAccountNameInAnyCase() {
        FindClientMeetingsAction.Response res = find('HALV', null, null, null);

        Assert.isTrue(res.success);
        Assert.areEqual(1, res.totalMatches);
        FindClientMeetingsAction.MeetingMatch m = res.meetings[0];
        Client_Meeting__c rec = [SELECT Id, Name FROM Client_Meeting__c WHERE Id = :SummaryTestData.meetingId(SummaryTestData.HALVERSON)];
        Assert.areEqual(rec.Id, m.meetingId);
        Assert.areEqual(rec.Name, m.meetingName);
        Assert.areEqual(SummaryTestData.HALVERSON, m.accountName);
        Assert.areEqual(SummaryTestData.MEETING_DATE, m.meetingDate);
        Assert.areEqual('Margaret Okafor (CFO), Tom Brennan (Corp Dev), our M&A team', m.attendees);
        Assert.areEqual('Not Generated', m.summaryStatus);
        Assert.isNull(m.summaryGeneratedAt);
        String expectedUrl = URL.getOrgDomainUrl().toExternalForm() + '/lightning/r/Client_Meeting__c/' + rec.Id + '/view';
        Assert.isTrue(m.recordUrl.startsWith(URL.getOrgDomainUrl().toExternalForm()), 'Absolute link: ' + m.recordUrl);
        Assert.areEqual(expectedUrl, m.recordUrl);
        Assert.areEqual(rec.Name + ' | Halverson Test | 2026-09-20 | Attendees: Margaret Okafor (CFO), Tom Brennan (Corp Dev), '
            + 'our M&A team | Summary: Not Generated | Id: ' + rec.Id, res.matchesText);
        // One match: the Id is handed over and the message carries the details and a link built in code.
        Assert.areEqual(rec.Id, res.selectedMeetingId);
        Assert.areEqual('Found 1 meeting matching client "HALV": ' + rec.Name + ' with Halverson Test on 2026-09-20. '
            + 'Summary: Not Generated. [Open ' + rec.Name + '](' + expectedUrl + ')', res.message);
    }

    @IsTest
    static void attendeeNamePartialAnyCase() {
        FindClientMeetingsAction.Response res = find(null, null, null, null, 'henrik');   // Henrik Aalto (CEO), Northwind

        Assert.areEqual(1, res.totalMatches);
        Assert.areEqual(SummaryTestData.NORTHWIND, res.meetings[0].accountName);
        Assert.isTrue(res.message.startsWith('Found 1 meeting matching attendee "henrik": '), res.message);

        Assert.areEqual(2, find(null, null, null, null, 'OKAFOR').totalMatches, 'Margaret Okafor: Halverson and Refi fixtures');
        Assert.areEqual(0, find('Northwind', null, null, null, 'Okafor').totalMatches, 'Combined with the client: AND');
        Assert.areEqual(0, find(null, null, null, null, 'Baltic Ferry Lines').totalMatches, 'A deal name is not an attendee');
    }

    @IsTest
    static void selectedMeetingIdOnlyForExactlyOneMatch() {
        // Empty string, never null: the agent script tests it with != "" and sets its variable from it on every search.
        Assert.areEqual('', find(null, SummaryTestData.MEETING_DATE, SummaryTestData.MEETING_DATE, null).selectedMeetingId, 'Several matches');
        Assert.areEqual('', find('Nonexistent', null, null, null).selectedMeetingId, 'No match');
        Assert.areEqual('', find(' ', null, null, null).selectedMeetingId, 'No input');
        Assert.areEqual(SummaryTestData.meetingId(SummaryTestData.NORTHWIND), find('Northwind', null, null, null).selectedMeetingId, 'Exactly one');
    }

    @IsTest
    static void selectedMeetingIdIsEmptyWithoutAccess() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User noAccess = new User(ProfileId = p.Id, LastName = 'NoAccess', Alias = 'noacc2',
            Username = 'noaccess2' + unique + '@example.com.test', Email = 'noaccess@example.com',
            TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        FindClientMeetingsAction.Response res;
        System.runAs(noAccess) {
            res = find('Northwind', null, null, null);
        }
        Assert.areEqual('', res.selectedMeetingId);
    }

    @IsTest
    static void neverReturnsNotesOrSummaryText() {
        Client_Meeting__c m = new Client_Meeting__c(Id = SummaryTestData.meetingId(SummaryTestData.HALVERSON),
            Summary__c = '<p>SECRET SUMMARY TEXT</p>', Summary_JSON__c = '{"x":"SECRET JSON"}');
        update m;

        FindClientMeetingsAction.Response res = find('Halverson', null, null, null);

        String everything = JSON.serialize(res);
        Assert.isFalse(everything.contains('Atlas update'), 'No meeting notes in any output');
        Assert.isFalse(everything.contains('SECRET'), 'No summary text or JSON in any output');
    }

    @IsTest
    static void singleDayWithMoreThanFiveMatches() {
        FindClientMeetingsAction.Response res = find(null, SummaryTestData.MEETING_DATE, SummaryTestData.MEETING_DATE, null);

        Assert.isTrue(res.success);
        Assert.areEqual(6, res.totalMatches, 'Total counts every match');
        Assert.areEqual(5, res.meetings.size(), 'At most 5 returned');
        Assert.areEqual(5, res.matchesText.split('\n').size());
        Assert.areEqual('Found 6 meetings matching date 2026-09-20; showing the 5 most recent. '
            + 'Ask the banker for a date or the meeting name to narrow it down.', res.message);
    }

    @IsTest
    static void dateRangeIsInclusiveAndNewestFirst() {
        addHalversonMeetings(new List<Date>{ Date.newInstance(2026, 10, 1), Date.newInstance(2026, 10, 5), Date.newInstance(2026, 10, 12) });

        FindClientMeetingsAction.Response res = find('halverson', Date.newInstance(2026, 9, 20), Date.newInstance(2026, 10, 5), null);

        Assert.areEqual(3, res.totalMatches, 'Both ends inclusive; 2026-10-12 is outside');
        Assert.areEqual(Date.newInstance(2026, 10, 5), res.meetings[0].meetingDate, 'Newest first');
        Assert.areEqual(Date.newInstance(2026, 10, 1), res.meetings[1].meetingDate);
        Assert.areEqual(SummaryTestData.MEETING_DATE, res.meetings[2].meetingDate);
        Assert.isTrue(res.message.startsWith('Found 3 meetings matching client "halverson", dates 2026-09-20 to 2026-10-05.'), res.message);
        Assert.isTrue(res.message.endsWith('Ask the banker which one, by name, client and date.'));
    }

    @IsTest
    static void openEndedRanges() {
        addHalversonMeetings(new List<Date>{ Date.newInstance(2026, 10, 1), Date.newInstance(2026, 10, 5) });

        FindClientMeetingsAction.Response fromOnly = find(null, Date.newInstance(2026, 10, 1), null, null);
        Assert.areEqual(2, fromOnly.totalMatches, 'Only Date From: everything from that day on');
        Assert.isTrue(fromOnly.message.contains('dates from 2026-10-01'), fromOnly.message);

        FindClientMeetingsAction.Response toOnly = find('Halverson', null, Date.newInstance(2026, 9, 30), null);
        Assert.areEqual(1, toOnly.totalMatches, 'Only Date To: everything up to that day');
        Assert.isTrue(toOnly.message.contains('dates up to 2026-09-30'), toOnly.message);
    }

    @IsTest
    static void moreThanFiveForOneClient() {
        addHalversonMeetings(new List<Date>{ Date.newInstance(2026, 8, 1), Date.newInstance(2026, 8, 15), Date.newInstance(2026, 9, 1),
            Date.newInstance(2026, 9, 10), Date.newInstance(2026, 10, 2), Date.newInstance(2026, 10, 9) });

        FindClientMeetingsAction.Response res = find('Halverson', null, null, null);

        Assert.areEqual(7, res.totalMatches);
        Assert.areEqual(5, res.meetings.size());
        List<Date> expected = new List<Date>{ Date.newInstance(2026, 10, 9), Date.newInstance(2026, 10, 2), SummaryTestData.MEETING_DATE,
            Date.newInstance(2026, 9, 10), Date.newInstance(2026, 9, 1) };
        for (Integer i = 0; i < 5; i++) {
            Assert.areEqual(expected[i], res.meetings[i].meetingDate, 'Position ' + i);
        }
        Assert.isTrue(res.message.contains('showing the 5 most recent'));
    }

    @IsTest
    static void meetingNameExactAnyCaseTrimmed() {
        Client_Meeting__c target = [SELECT Id, Name FROM Client_Meeting__c WHERE Id = :SummaryTestData.meetingId(SummaryTestData.NORTHWIND)];

        FindClientMeetingsAction.Response res = find(null, null, null, '  ' + target.Name.toLowerCase() + ' ');

        Assert.areEqual(1, res.totalMatches);
        Assert.areEqual(target.Id, res.meetings[0].meetingId);
        Assert.areEqual(SummaryTestData.NORTHWIND, res.meetings[0].accountName);
    }

    @IsTest
    static void filtersCombineWithAnd() {
        Assert.areEqual(6, find('test', SummaryTestData.MEETING_DATE, SummaryTestData.MEETING_DATE, null).totalMatches);
        Assert.areEqual(1, find('northwind', SummaryTestData.MEETING_DATE, SummaryTestData.MEETING_DATE, null).totalMatches);
        Assert.areEqual(0, find('northwind', Date.newInstance(2026, 10, 1), null, null).totalMatches);
    }

    @IsTest
    static void noMatchExplainsWhatToAsk() {
        FindClientMeetingsAction.Response res = find('Nonexistent Holdings', null, null, null);

        Assert.isTrue(res.success, 'A search with no results still succeeded');
        Assert.areEqual(0, res.totalMatches);
        Assert.isTrue(res.meetings.isEmpty());
        Assert.isNull(res.matchesText);
        Assert.areEqual('No client meetings match client "Nonexistent Holdings". Check the spelling, '
            + 'or ask the banker for the client, the date or the meeting name.', res.message);
    }

    @IsTest
    static void wildcardsMatchLiterally() {
        Assert.areEqual(0, find('%', null, null, null).totalMatches, '"%" must not match every account');
        Assert.areEqual(0, find('_', null, null, null).totalMatches, '"_" must not match every account');
    }

    @IsTest
    static void noInputsIsAClearMessage() {
        FindClientMeetingsAction.Response res = find('  ', null, null, ' ', '');
        Assert.isFalse(res.success);
        Assert.areEqual(FindClientMeetingsAction.MESSAGE_NO_INPUT, res.message);

        FindClientMeetingsAction.Response nullRequest = FindClientMeetingsAction.find(new List<FindClientMeetingsAction.Request>{ null })[0];
        Assert.areEqual(FindClientMeetingsAction.MESSAGE_NO_INPUT, nullRequest.message);
    }

    @IsTest
    static void existingSummaryIsShownWithItsTime() {
        Datetime generated = Datetime.newInstance(2026, 10, 12, 14, 30, 0);
        update new Client_Meeting__c(Id = SummaryTestData.meetingId(SummaryTestData.HALVERSON),
            Summary_Status__c = 'Generated (Repaired)', Summary_Generated_At__c = generated);

        FindClientMeetingsAction.Response res = find('Halverson', null, null, null);

        Assert.areEqual('Generated (Repaired)', res.meetings[0].summaryStatus);
        Assert.areEqual(generated, res.meetings[0].summaryGeneratedAt);
        Assert.isTrue(res.matchesText.contains('| Summary: Generated (Repaired), generated ' + generated.format('yyyy-MM-dd HH:mm z') + ' |'),
            res.matchesText);
    }

    @IsTest
    static void userWithoutAccessGetsAMessageNotAnError() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User noAccess = new User(ProfileId = p.Id, LastName = 'NoAccess', Alias = 'noacc',
            Username = 'noaccess' + unique + '@example.com.test', Email = 'noaccess@example.com',
            TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');

        FindClientMeetingsAction.Response res;
        System.runAs(noAccess) {
            res = find('Halverson', null, null, null);
        }

        Assert.isFalse(res.success);
        Assert.areEqual(0, res.totalMatches);
        Assert.areEqual(FindClientMeetingsAction.MESSAGE_NO_ACCESS, res.message);
    }

    @IsTest
    static void tooManyRequestsInOneCall() {
        List<FindClientMeetingsAction.Request> reqs = new List<FindClientMeetingsAction.Request>();
        for (Integer i = 0; i <= FindClientMeetingsAction.MAX_PER_CALL; i++) {
            FindClientMeetingsAction.Request r = new FindClientMeetingsAction.Request();
            r.accountName = 'Halverson';
            reqs.add(r);
        }

        List<FindClientMeetingsAction.Response> res = FindClientMeetingsAction.find(reqs);

        Assert.areEqual(1, res[0].totalMatches);
        Assert.isTrue(res[FindClientMeetingsAction.MAX_PER_CALL].message.startsWith('Too many searches in one request'));
    }
}
