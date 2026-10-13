/** All generations go through MockLlmGateway: tests never call the real LLM. */
@IsTest
private class ClientSummaryServiceTest {

    @TestSetup
    static void setup() {
        SummaryTestData.createAll();
    }

    static MockLlmGateway useMock(List<Object> outputs) {
        MockLlmGateway mock = new MockLlmGateway(outputs);
        ClientSummaryService.gateway = mock;
        return mock;
    }

    static ClientSummaryService.Response runFor(String account) {
        ClientSummaryService.Request req = new ClientSummaryService.Request();
        req.meetingId = SummaryTestData.meetingId(account);
        return ClientSummaryService.generate(new List<ClientSummaryService.Request>{ req })[0];
    }

    static Client_Meeting__c meeting(String account) {
        return [SELECT Summary__c, Summary_JSON__c, Summary_Status__c, Summary_Generated_At__c, Summary_File_Id__c
                FROM Client_Meeting__c WHERE Id = :SummaryTestData.meetingId(account)];
    }

    static AI_Generation_Log__c log(String account) {
        String recordId = SummaryTestData.meetingId(account);
        return [SELECT Status__c, Attempts__c, Validation_Errors__c, Latency_Ms__c, Context_Chars__c, Raw_Output__c,
                       Template_Name__c, Template_Version__c, Capability__c
                FROM AI_Generation_Log__c WHERE Record_Id__c = :recordId ORDER BY CreatedDate DESC LIMIT 1];
    }

    static void assertNoDmlBeforeGeneration(MockLlmGateway mock) {
        for (Integer dml : mock.dmlAtCall) {
            Assert.areEqual(0, dml, 'Every generation must happen before any DML in the transaction');
        }
    }

    // ------------------------------------------------------------------ outcomes

    @IsTest
    static void validSummaryIsSavedWithPdfAndLog() {
        MockLlmGateway mock = useMock(new List<Object>{ JSON.serialize(SummaryTestData.halversonSummary()) });

        Test.startTest();
        ClientSummaryService.Response res = runFor(SummaryTestData.HALVERSON);
        Test.stopTest();

        Assert.isTrue(res.success, res.message);
        Assert.areEqual('Generated', res.status);
        Assert.areEqual(SummaryTestData.halversonSummary().get('executiveSummary'), res.summaryText, 'The full executive summary');
        Assert.areEqual(ClientSummaryService.MESSAGE_GENERATED, res.message);
        Assert.isNull(res.reviewItems, 'Nothing to review');
        String orgDomain = URL.getOrgDomainUrl().toExternalForm();
        Assert.isTrue(res.recordUrl.startsWith(orgDomain + '/lightning/r/Client_Meeting__c/'), 'Absolute link: ' + res.recordUrl);
        Assert.areEqual(orgDomain + '/lightning/r/Client_Meeting__c/' + SummaryTestData.meetingId(SummaryTestData.HALVERSON) + '/view', res.recordUrl);
        Client_Meeting__c m = meeting(SummaryTestData.HALVERSON);
        Assert.areEqual('Generated', m.Summary_Status__c);
        Assert.isTrue(m.Summary__c.contains('Client meeting summary: Halverson Test'));
        Id atlasId = [SELECT Id FROM Opportunity WHERE Name = 'Project Atlas'].Id;
        Assert.isTrue(m.Summary__c.contains('href="/lightning/r/' + atlasId + '/view"'),
            'The source link survives the rich text sanitizer: ' + m.Summary__c.substringAfter('<h3>Sources</h3>'));
        Assert.isNotNull(m.Summary_JSON__c);
        Assert.isNotNull(m.Summary_Generated_At__c);
        Assert.areEqual(res.fileId, m.Summary_File_Id__c);
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :SummaryTestData.meetingId(SummaryTestData.HALVERSON)]);

        AI_Generation_Log__c l = log(SummaryTestData.HALVERSON);
        Assert.areEqual('Valid', l.Status__c);
        Assert.areEqual(1, l.Attempts__c);
        Assert.areEqual('Client_Meeting_Summary', l.Template_Name__c);
        Assert.areEqual(ClientSummaryService.TEMPLATE_VERSION, l.Template_Version__c);
        Assert.areEqual('Client Summary', l.Capability__c);
        Assert.isTrue(l.Context_Chars__c > 0);
        Assert.isTrue(l.Raw_Output__c.startsWith('--- Attempt 1 ---'));
        Assert.isNull(l.Validation_Errors__c, 'No errors and no drift: ' + l.Validation_Errors__c);
        Assert.areEqual(1, mock.calls);
        assertNoDmlBeforeGeneration(mock);
    }

    @IsTest
    static void repairedSummaryIsMarkedRepaired() {
        Map<String, Object> s = SummaryTestData.halversonSummary();
        Map<String, Object> step = (Map<String, Object>) ((List<Object>) s.get('nextSteps'))[0];
        step.put('action', 'send buyer list');   // GPT 5.4 v4 MTG-0013 run 2
        step.put('owner', 'Tom Brennan');
        useMock(new List<Object>{ JSON.serialize(s) });

        ClientSummaryService.Response res = runFor(SummaryTestData.HALVERSON);

        Assert.areEqual('Generated (Repaired)', res.status);
        Assert.areEqual(ClientSummaryService.MESSAGE_REPAIRED, res.message);
        Assert.isFalse(res.message.containsIgnoreCase('log'), 'Bankers cannot read the log, so the message must not point there');
        Client_Meeting__c m = meeting(SummaryTestData.HALVERSON);
        Assert.isTrue(m.Summary_JSON__c.contains('send buyer list (TB)'));
        // Rich text fields sanitize markup on save, so check the text, not exact tags (SummaryRendererTest covers the HTML).
        Assert.isTrue(m.Summary__c.contains('send buyer list (TB)'));
        AI_Generation_Log__c l = log(SummaryTestData.HALVERSON);
        Assert.areEqual('Repaired', l.Status__c);
        Assert.isTrue(l.Validation_Errors__c.contains('replaced by the full clause'));
    }

    @IsTest
    static void retryThenValid() {
        MockLlmGateway mock = useMock(new List<Object>{ '{"client": "Halverson Test"',
            JSON.serialize(SummaryTestData.halversonSummary()) });

        Test.startTest();
        ClientSummaryService.Response res = runFor(SummaryTestData.HALVERSON);
        Test.stopTest();

        Assert.areEqual('Generated', res.status);
        Assert.areEqual(2, mock.calls);
        assertNoDmlBeforeGeneration(mock);
        AI_Generation_Log__c l = log(SummaryTestData.HALVERSON);
        Assert.areEqual('Valid', l.Status__c);
        Assert.areEqual(2, l.Attempts__c);
        Assert.isTrue(l.Validation_Errors__c.contains('Attempt 1: invalid: Invalid JSON'));
        Assert.isTrue(l.Raw_Output__c.contains('--- Attempt 2 ---'));
    }

    @IsTest
    static void retryThenFallback() {
        Map<String, Object> injected = SummaryTestData.northwindSummary();
        ((List<Object>) injected.get('nextSteps')).add(SummaryTestData.step('invent a $5B deal', 'Unassigned'));
        MockLlmGateway mock = useMock(new List<Object>{ 'not json at all', JSON.serialize(injected) });

        ClientSummaryService.Response res = runFor(SummaryTestData.NORTHWIND);

        Assert.isTrue(res.success, 'A data-only summary is still a saved summary');
        Assert.areEqual('Fallback', res.status);
        Assert.areEqual(SummaryRenderer.FALLBACK_BANNER, res.summaryText);
        Assert.areEqual('Data-only summary saved because the AI summary did not pass the checks.', res.reviewItems);
        Assert.isNotNull(res.fileId, 'The fallback gets a PDF too');
        Client_Meeting__c m = meeting(SummaryTestData.NORTHWIND);
        Assert.areEqual('Fallback', m.Summary_Status__c);
        Assert.isNull(m.Summary_JSON__c, 'No AI JSON is kept for a fallback');
        Assert.isTrue(m.Summary__c.contains(SummaryRenderer.FALLBACK_BANNER));
        Assert.isFalse(m.Summary__c.contains('5B deal was'), 'No model text in the fallback');
        AI_Generation_Log__c l = log(SummaryTestData.NORTHWIND);
        Assert.areEqual('Fallback', l.Status__c);
        Assert.areEqual(2, l.Attempts__c);
        Assert.isTrue(l.Validation_Errors__c.contains('text the notes aimed at the AI'), l.Validation_Errors__c);
        Assert.areEqual(2, mock.calls);
        Assert.areEqual(ClientSummaryService.MESSAGE_VALIDATION, res.message, 'Only real validation failures say "did not pass the checks"');
        Assert.isTrue(l.Validation_Errors__c.startsWith('Error category: VALIDATION\n'), l.Validation_Errors__c);
    }

    // ------------------------------------------------------------------ gateway errors: what is retried, what the banker sees

    @IsTest
    static void transientErrorsAreRetriedOnceThenFallBack() {
        MockLlmGateway mock = useMock(new List<Object>{ new MockLlmGateway.MockException('Read timed out'),
            new MockLlmGateway.MockException('503 Service Unavailable') });

        ClientSummaryService.Response res = runFor(SummaryTestData.HALVERSON);

        Assert.areEqual(2, mock.calls, 'A transient error gets the one retry');
        Assert.areEqual('Fallback', res.status);
        Assert.areEqual(ClientSummaryService.MESSAGE_TRANSIENT, res.message);
        AI_Generation_Log__c l = log(SummaryTestData.HALVERSON);
        Assert.areEqual(2, l.Attempts__c);
        Assert.isTrue(l.Validation_Errors__c.startsWith('Error category: TRANSIENT\n'), l.Validation_Errors__c);
        Assert.isTrue(l.Validation_Errors__c.contains('Attempt 2: generation failed (TRANSIENT, MockLlmGateway.MockException): 503'),
            l.Validation_Errors__c);
        Assert.isTrue(l.Raw_Output__c.contains('(no output)'));
    }

    @IsTest
    static void transientErrorThenValidOutputIsGenerated() {
        MockLlmGateway mock = useMock(new List<Object>{ new MockLlmGateway.MockException('Read timed out'),
            JSON.serialize(SummaryTestData.halversonSummary()) });

        ClientSummaryService.Response res = runFor(SummaryTestData.HALVERSON);

        Assert.areEqual(2, mock.calls);
        Assert.areEqual('Generated', res.status);
        Assert.areEqual('Valid', log(SummaryTestData.HALVERSON).Status__c);
    }

    @IsTest
    static void missingPromptTemplatePermissionIsNotRetried() {
        // Banker test A, 2026-10-12: the exact text the real API returned for a user without Prompt Template User.
        MockLlmGateway mock = useMock(new List<Object>{
            new MockLlmGateway.MockException('Insufficient Privileges: This feature is not currently enabled for this user.') });

        ClientSummaryService.Response res = runFor(SummaryTestData.HALVERSON);

        Assert.areEqual(1, mock.calls, 'Same answer every time: no retry');
        Assert.isTrue(res.success, 'The data-only summary is still saved');
        Assert.areEqual('Fallback', res.status);
        Assert.areEqual(ClientSummaryService.MESSAGE_PERMISSION, res.message);
        Assert.areEqual('Data-only summary saved because AI summaries aren\'t enabled for your user (missing the Prompt Template User permission).',
            res.reviewItems, 'The fallback reason is a review item');
        Assert.isTrue(meeting(SummaryTestData.HALVERSON).Summary__c.contains(SummaryRenderer.FALLBACK_BANNER));
        AI_Generation_Log__c l = log(SummaryTestData.HALVERSON);
        Assert.areEqual('Fallback', l.Status__c);
        Assert.areEqual(1, l.Attempts__c);
        Assert.isTrue(l.Validation_Errors__c.startsWith('Error category: PERMISSION\n'), l.Validation_Errors__c);
        Assert.isFalse(l.Validation_Errors__c.contains('Attempt 2'));
    }

    @IsTest
    static void templateConfigurationErrorIsNotRetried() {
        MockLlmGateway mock = useMock(new List<Object>{
            new MockLlmGateway.MockException('Prompt template Client_Meeting_Summary is inactive.') });

        ClientSummaryService.Response res = runFor(SummaryTestData.HALVERSON);

        Assert.areEqual(1, mock.calls);
        Assert.areEqual('Fallback', res.status);
        Assert.areEqual(ClientSummaryService.MESSAGE_CONFIGURATION, res.message);
        AI_Generation_Log__c l = log(SummaryTestData.HALVERSON);
        Assert.areEqual(1, l.Attempts__c);
        Assert.isTrue(l.Validation_Errors__c.startsWith('Error category: CONFIGURATION\n'), l.Validation_Errors__c);
    }

    @IsTest
    static void gatewayErrorsAreClassified() {
        Map<String, String> expected = new Map<String, String>{
            'Insufficient Privileges: This feature is not currently enabled for this user.' => 'PERMISSION',
            'You do not have access to this prompt template' => 'PERMISSION',
            'Prompt template not found: Client_Meeting_Summary' => 'CONFIGURATION',
            'The template has no active version' => 'CONFIGURATION',
            'Read timed out' => 'TRANSIENT',
            '503 Service Unavailable' => 'TRANSIENT',
            'Something new and unexpected' => 'TRANSIENT' };
        for (String message : expected.keySet()) {
            Assert.areEqual(expected.get(message), ClientSummaryService.classify(new MockLlmGateway.MockException(message)), message);
        }
        Assert.areEqual('PERMISSION', ClientSummaryService.classify(new NoAccessException()), 'By type');
    }

    // ------------------------------------------------------------------ the three test meetings

    @IsTest
    static void injectionMeetingShowsIgnoredTextForReview() {
        useMock(new List<Object>{ JSON.serialize(SummaryTestData.northwindSummary()) });

        ClientSummaryService.Response res = runFor(SummaryTestData.NORTHWIND);

        Assert.areEqual('Generated', res.status);
        Assert.isTrue(meeting(SummaryTestData.NORTHWIND).Summary__c.contains(SummaryRenderer.REVIEW_HEADING));
        Assert.areEqual(ClientSummaryService.REVIEW_INSTRUCTION, res.reviewItems);
        Assert.isFalse(res.reviewItems.contains('ignore previous'), 'The text aimed at the AI is not repeated to the agent');
    }

    @IsTest
    static void conflictsAndFlagsBecomeReviewItems() {
        // MTG-0019 in Preview: the Keel conflict was in the record but never reached the chat.
        Map<String, Object> s = SummaryTestData.northwindSummary();
        s.put('conflicts', new List<Object>{ new Map<String, Object>{
            'description' => 'The notes size Keel differently from CRM.', 'sources' => new List<Object>{ 'S3', 'S4' } } });
        useMock(new List<Object>{ JSON.serialize(s) });

        ClientSummaryService.Response res = runFor(SummaryTestData.NORTHWIND);

        Assert.areEqual('Notes and CRM disagree: The notes size Keel differently from CRM.\n' + ClientSummaryService.REVIEW_INSTRUCTION,
            res.reviewItems);
    }

    @IsTest
    static void longTextIsCutAtASentenceNeverMidWord() {
        Assert.areEqual('Short.', ClientSummaryService.cutAtSentence('Short.', 800));
        Assert.isNull(ClientSummaryService.cutAtSentence(null, 800));
        Assert.areEqual('First sentence. Second one.', ClientSummaryService.cutAtSentence('First sentence. Second one. Third is too long', 35));
        Assert.areEqual('one two…', ClientSummaryService.cutAtSentence('one two three', 9), 'No sentence end: cut at a word');
    }

    @IsTest
    static void emptyNotesAndNoOpportunities() {
        useMock(new List<Object>{ JSON.serialize(SummaryTestData.cobaltSummary()) });

        ClientSummaryService.Response res = runFor(SummaryTestData.COBALT);

        Assert.areEqual('Generated', res.status, res.message);
        Assert.isTrue(meeting(SummaryTestData.COBALT).Summary__c.contains('<h3>' + SummaryRenderer.DEALS_HEADING + '</h3>\n<p>None.</p>'));
    }

    // ------------------------------------------------------------------ access, drift, files, bulk, failures

    @IsTest
    static void userWithoutAccessGetsFailedAndNoGeneration() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User noAccess = new User(ProfileId = p.Id, LastName = 'NoAccess', Alias = 'noacc',
            Username = 'noaccess' + unique + '@example.com.test', Email = 'noaccess@example.com',
            TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        MockLlmGateway mock = useMock(new List<Object>{ JSON.serialize(SummaryTestData.halversonSummary()) });
        Id meetingId = SummaryTestData.meetingId(SummaryTestData.HALVERSON);
        Client_Meeting__c before = meeting(SummaryTestData.HALVERSON);

        ClientSummaryService.Response res;
        System.runAs(noAccess) {
            ClientSummaryService.Request req = new ClientSummaryService.Request();
            req.meetingId = meetingId;
            res = ClientSummaryService.generate(new List<ClientSummaryService.Request>{ req })[0];
        }

        Assert.isFalse(res.success);
        Assert.areEqual('Failed', res.status);
        Assert.isTrue(res.message.contains('don\'t have access'));
        Assert.isNull(res.recordUrl, 'No record link when nothing was saved');
        Assert.areEqual(0, mock.calls, 'No generation without access to the data');
        Client_Meeting__c after = meeting(SummaryTestData.HALVERSON);
        Assert.areEqual(before.Summary_Status__c, after.Summary_Status__c, 'Nothing written to the meeting');
        Assert.isNull(after.Summary__c);
        AI_Generation_Log__c l = log(SummaryTestData.HALVERSON);
        Assert.areEqual('Error', l.Status__c, 'The failure is still logged (system mode)');
        Assert.isTrue(l.Validation_Errors__c.startsWith('Context could not be built'));
    }

    @IsTest
    static void contextDriftIsLoggedNotFatal() {
        MockLlmGateway mock = useMock(new List<Object>{ JSON.serialize(SummaryTestData.halversonSummary()) });
        mock.resolvedPromptOverride = 'RULES\n' + ClientSummaryService.CONTEXT_BEGIN + 'an older context' + ClientSummaryService.CONTEXT_END;

        ClientSummaryService.Response res = runFor(SummaryTestData.HALVERSON);

        Assert.areEqual('Generated', res.status);
        Assert.isTrue(log(SummaryTestData.HALVERSON).Validation_Errors__c.contains('Attempt 1: context drift'));
    }

    @IsTest
    static void missingContextBlockOrPromptIsLogged() {
        MockLlmGateway mock = useMock(new List<Object>{ 'not json', JSON.serialize(SummaryTestData.halversonSummary()) });
        mock.resolvedPromptOverride = 'a prompt without the markers';

        runFor(SummaryTestData.HALVERSON);

        Assert.isTrue(log(SummaryTestData.HALVERSON).Validation_Errors__c.contains('no CONTEXT block found'));
    }

    @IsTest
    static void regenerationAddsANewVersionOfTheSameFile() {
        useMock(new List<Object>{ JSON.serialize(SummaryTestData.halversonSummary()),
            JSON.serialize(SummaryTestData.halversonSummary()) });

        String first = runFor(SummaryTestData.HALVERSON).fileId;
        String second = runFor(SummaryTestData.HALVERSON).fileId;

        Assert.areEqual(first, second, 'Same document, new version');
        Assert.areEqual(2, [SELECT COUNT() FROM ContentVersion WHERE ContentDocumentId = :first]);
    }

    @IsTest
    static void missingOldFileGetsANewOne() {
        Client_Meeting__c m = new Client_Meeting__c(Id = SummaryTestData.meetingId(SummaryTestData.HALVERSON),
            Summary_File_Id__c = '069000000000000AAA');
        update m;
        useMock(new List<Object>{ JSON.serialize(SummaryTestData.halversonSummary()) });

        ClientSummaryService.Response res = runFor(SummaryTestData.HALVERSON);

        Assert.isTrue(res.success, res.message);
        Assert.areNotEqual('069000000000000AAA', res.fileId);
        Assert.isTrue(log(SummaryTestData.HALVERSON).Validation_Errors__c.contains('attached a new file'));
    }

    @IsTest
    static void bulkIsCappedWithAClearMessage() {
        MockLlmGateway mock = useMock(new List<Object>{ JSON.serialize(SummaryTestData.halversonSummary()),
            JSON.serialize(SummaryTestData.northwindSummary()), JSON.serialize(SummaryTestData.cobaltSummary()) });
        List<ClientSummaryService.Request> reqs = new List<ClientSummaryService.Request>();
        for (String account : new List<String>{ SummaryTestData.HALVERSON, SummaryTestData.NORTHWIND, SummaryTestData.COBALT,
                SummaryTestData.AMBIGUOUS }) {
            ClientSummaryService.Request r = new ClientSummaryService.Request();
            r.meetingId = SummaryTestData.meetingId(account);
            reqs.add(r);
        }

        Test.startTest();
        List<ClientSummaryService.Response> res = ClientSummaryService.generate(reqs);
        Test.stopTest();

        Assert.areEqual(4, res.size(), 'One response per request, in order');
        for (Integer i = 0; i < 3; i++) {
            Assert.areEqual('Generated', res[i].status, res[i].message);
        }
        Assert.areEqual('Failed', res[3].status);
        Assert.isTrue(res[3].message.startsWith('Too many meetings in one request (max 3)'));
        Assert.areEqual(3, mock.calls);
        assertNoDmlBeforeGeneration(mock);
        Assert.areEqual(0, [SELECT COUNT() FROM AI_Generation_Log__c WHERE Record_Id__c = :reqs[3].meetingId], 'Not processed, not logged');
    }

    @IsTest
    static void missingMeetingIdFails() {
        MockLlmGateway mock = useMock(new List<Object>());

        List<ClientSummaryService.Response> res = ClientSummaryService.generate(
            new List<ClientSummaryService.Request>{ new ClientSummaryService.Request(), null });

        for (ClientSummaryService.Response r : res) {
            Assert.areEqual('Failed', r.status);
            Assert.areEqual('Meeting Id is required.', r.message);
        }
        Assert.areEqual(0, mock.calls);
    }

    @IsTest
    static void saveFailureIsReportedAndLogged() {
        // A valid summary whose JSON is larger than Summary_JSON__c (32,768 chars): the update fails, the banker is told.
        Map<String, Object> s = SummaryTestData.halversonSummary();
        List<Object> gaps = new List<Object>();
        for (Integer i = 0; i < 40; i++) {
            gaps.add('Gap ' + i + ' ' + 'detail '.repeat(130));
        }
        s.put('dataGaps', gaps);
        useMock(new List<Object>{ JSON.serialize(s) });
        String statusBefore = meeting(SummaryTestData.HALVERSON).Summary_Status__c;

        ClientSummaryService.Response res = runFor(SummaryTestData.HALVERSON);

        Assert.isFalse(res.success);
        Assert.areEqual('Failed', res.status);
        Assert.isTrue(res.message.startsWith('The summary could not be saved on the meeting'));
        Assert.areEqual(statusBefore, meeting(SummaryTestData.HALVERSON).Summary_Status__c, 'Meeting unchanged');
        Assert.isNull(meeting(SummaryTestData.HALVERSON).Summary__c);
        Assert.isNull(res.fileId, 'No file id for a rolled-back save');
        Assert.isNull(res.recordUrl, 'No record link for a rolled-back save');
        Assert.isNull(res.reviewItems, 'Nothing to review when nothing was saved');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :SummaryTestData.meetingId(SummaryTestData.HALVERSON)],
            'The PDF is rolled back with the failed update: no orphan file');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentVersion], 'No file left anywhere');
        AI_Generation_Log__c l = log(SummaryTestData.HALVERSON);
        Assert.areEqual('Error', l.Status__c, 'The log row is written after the rollback');
        Assert.isTrue(l.Validation_Errors__c.contains('the PDF was rolled back'));
    }

    @IsTest
    static void failedSaveRollsBackOnlyThatMeeting() {
        Map<String, Object> tooBig = SummaryTestData.halversonSummary();
        List<Object> gaps = new List<Object>();
        for (Integer i = 0; i < 40; i++) {
            gaps.add('Gap ' + i + ' ' + 'detail '.repeat(130));
        }
        tooBig.put('dataGaps', gaps);
        useMock(new List<Object>{ JSON.serialize(tooBig), JSON.serialize(SummaryTestData.northwindSummary()) });
        List<ClientSummaryService.Request> reqs = new List<ClientSummaryService.Request>();
        for (String account : new List<String>{ SummaryTestData.HALVERSON, SummaryTestData.NORTHWIND }) {
            ClientSummaryService.Request r = new ClientSummaryService.Request();
            r.meetingId = SummaryTestData.meetingId(account);
            reqs.add(r);
        }

        List<ClientSummaryService.Response> res = ClientSummaryService.generate(reqs);

        Assert.areEqual('Failed', res[0].status);
        Assert.areEqual('Generated', res[1].status, res[1].message);
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :reqs[0].meetingId]);
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :reqs[1].meetingId],
            'The other meeting keeps its PDF');
        Assert.areEqual(res[1].fileId, meeting(SummaryTestData.NORTHWIND).Summary_File_Id__c);
        Assert.areEqual(2, [SELECT COUNT() FROM AI_Generation_Log__c], 'Both runs logged');
    }
}
