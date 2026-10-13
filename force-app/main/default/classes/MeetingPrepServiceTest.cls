/** All generations go through MockLlmGateway: tests never call the real LLM. */
@IsTest
private class MeetingPrepServiceTest {

    @TestSetup
    static void setup() {
        SummaryTestData.createAll();
    }

    static Id accountId(String name) {
        return [SELECT Id FROM Account WHERE Name = :name].Id;
    }

    static ClientContextBuilder.Context ctx(String name) {
        return ClientContextBuilder.buildAccountContext(accountId(name));
    }

    static String idOf(ClientContextBuilder.Context c, String refPrefix) {
        for (String id : c.sources.keySet()) {
            if (c.sources.get(id).startsWith(refPrefix)) {
                return id;
            }
        }
        return null;
    }

    static MockLlmGateway useMock(List<Object> outputs) {
        MockLlmGateway mock = new MockLlmGateway(outputs);
        MeetingPrepService.gateway = mock;
        return mock;
    }

    static MeetingPrepService.Response askClient(String accountName, String question) {
        return askId(accountId(accountName), question);
    }

    static MeetingPrepService.Response askId(String accountIdText, String question) {
        MeetingPrepService.Request req = new MeetingPrepService.Request();
        req.accountId = accountIdText;
        req.question = question;
        return MeetingPrepService.answer(new List<MeetingPrepService.Request>{ req })[0];
    }

    static String answerJson(List<Object> sentences, List<String> ignored) {
        return JSON.serialize(new Map<String, Object>{ 'answerable' => true, 'sentences' => sentences, 'missing' => new List<Object>(),
            'ignoredInstructions' => ignored == null ? new List<String>() : ignored });
    }

    static Map<String, Object> sentence(String text, List<String> sources) {
        return new Map<String, Object>{ 'text' => text, 'sources' => sources };
    }

    static AI_Generation_Log__c log(Id recordId) {
        String rid = recordId;
        return [SELECT Capability__c, Template_Name__c, Template_Version__c, Status__c, Attempts__c, Validation_Errors__c,
                       Context_Chars__c, Raw_Output__c
                FROM AI_Generation_Log__c WHERE Record_Id__c = :rid ORDER BY CreatedDate DESC, Id DESC LIMIT 1];
    }

    static String meetingName(String accountName) {
        return [SELECT Name FROM Client_Meeting__c WHERE Account__r.Name = :accountName LIMIT 1].Name;
    }

    // ------------------------------------------------------------------ answered

    @IsTest
    static void answerHasReadableLabelsAndCodeBuiltLinks() {
        ClientContextBuilder.Context c = ctx(SummaryTestData.REFI);
        String notes = idOf(c, 'Client_Meeting__c.Meeting_Notes__c:');
        String question = '  What tenor did we discuss, and who was less sure?  ';
        MockLlmGateway mock = useMock(new List<Object>{ answerJson(new List<Object>{
            sentence('They discussed a 7 versus 10 year tenor.', new List<String>{ notes }),
            sentence('Margaret Okafor was less sure.', new List<String>{ notes }) }, null) });

        Test.startTest();   // fresh limits: Limits.getDmlStatements() then counts only this call's DML
        MeetingPrepService.Response res = askClient(SummaryTestData.REFI, question);
        Test.stopTest();

        Id meeting = [SELECT Id FROM Client_Meeting__c WHERE Account__r.Name = :SummaryTestData.REFI].Id;
        String label = 'Meeting ' + meetingName(SummaryTestData.REFI) + ', 2026-09-20';
        Assert.isTrue(res.success, res.message);
        Assert.areEqual(MeetingPrepService.STATUS_ANSWERED, res.status);
        Assert.areEqual('They discussed a 7 versus 10 year tenor. [' + label + ']\nMargaret Okafor was less sure. [' + label + ']', res.answer);
        Assert.areEqual(label + ': ' + URL.getOrgDomainUrl().toExternalForm() + '/lightning/r/Client_Meeting__c/' + meeting + '/view',
            res.sources, 'One plain link line per cited record, built in code');
        Assert.areEqual(MeetingPrepService.MESSAGE_ANSWERED, res.message);
        Assert.isNull(res.reviewItems);

        Assert.areEqual(question.trim(), mock.lastInputs.get('Input:Question'), 'The question is passed as asked');
        Assert.areEqual(accountId(SummaryTestData.REFI), mock.lastInputs.get('Input:Account'));
        for (Integer dml : mock.dmlAtCall) {
            Assert.areEqual(0, dml, 'Every generation happens before any DML');
        }
        AI_Generation_Log__c l = log(accountId(SummaryTestData.REFI));
        Assert.areEqual('Meeting Prep', l.Capability__c);
        Assert.areEqual('Meeting_Prep_QA', l.Template_Name__c);
        Assert.areEqual(MeetingPrepService.TEMPLATE_VERSION, l.Template_Version__c);
        Assert.areEqual('Valid', l.Status__c);
        Assert.areEqual(1, l.Attempts__c);
        Assert.isTrue(l.Context_Chars__c > 0);
        Assert.isNull(l.Validation_Errors__c, 'No drift, no repairs: ' + l.Validation_Errors__c);
    }

    @IsTest
    static void labelsForDealsClientAndActivity() {
        ClientContextBuilder.Context c = ctx(SummaryTestData.HALVERSON);
        String atlas;
        for (String id : c.sources.keySet()) {
            if (c.sources.get(id).startsWith('Opportunity:') && c.sourceText.get(id).contains('Project Atlas')) {
                atlas = id;
            }
        }
        String task = idOf(c, 'Task:');
        useMock(new List<Object>{ answerJson(new List<Object>{
            sentence('Project Atlas is at Negotiation/Review for USD 1,200,000,000.', new List<String>{ atlas, 'S1' }),
            sentence('Atlas is the sell-side deal.', new List<String>{ atlas }),
            sentence('The buyer list was sent to T. Brennan.', new List<String>{ task }) }, null) });

        MeetingPrepService.Response res = askClient(SummaryTestData.HALVERSON, 'Where does the sale stand?');

        Assert.areEqual(MeetingPrepService.STATUS_ANSWERED, res.status, res.message + ' ' + res.answer);
        Assert.isTrue(res.answer.startsWith('Project Atlas is at Negotiation/Review for USD 1,200,000,000. [Opportunity: Project Atlas; Client record: Halverson Test]'), res.answer);
        Assert.isTrue(res.answer.contains('[Activity: Send updated buyer list to T. Brennan ('), res.answer);
        List<String> lines = res.sources.split('\n');
        Assert.areEqual(3, lines.size(), 'One line per cited record (Atlas cited twice): ' + res.sources);
        Assert.isTrue(lines[0].startsWith('Opportunity: Project Atlas: https://'));
        Assert.isTrue(lines[1].startsWith('Client record: Halverson Test: https://') && lines[1].contains('/lightning/r/Account/'));
        Assert.isTrue(lines[2].contains('/lightning/r/Task/'));
    }

    @IsTest
    static void repairedAndNotAnswerable() {
        ClientContextBuilder.Context c = ctx(SummaryTestData.REFI);
        String notes = idOf(c, 'Client_Meeting__c.Meeting_Notes__c:');
        useMock(new List<Object>{
            '```json\n' + answerJson(new List<Object>{ sentence('They discussed a 7 versus 10 year tenor.', new List<String>{ notes }) }, null) + '\n```',
            JSON.serialize(new Map<String, Object>{ 'answerable' => false, 'sentences' => new List<Object>(),
                'missing' => new List<Object>{ 'Fee terms are not in the CRM record.' }, 'ignoredInstructions' => new List<Object>() }) });

        MeetingPrepService.Response repaired = askClient(SummaryTestData.REFI, 'What tenor did we discuss?');
        Assert.areEqual(MeetingPrepService.STATUS_REPAIRED, repaired.status);
        Assert.areEqual(MeetingPrepService.MESSAGE_REPAIRED, repaired.message);
        Assert.areEqual('Repaired', log(accountId(SummaryTestData.REFI)).Status__c);

        MeetingPrepService.Response no = askClient(SummaryTestData.REFI, 'What fee will they pay?');
        Assert.isTrue(no.success);
        Assert.areEqual(MeetingPrepService.STATUS_NOT_ANSWERABLE, no.status);
        Assert.areEqual(MeetingPrepService.ANSWER_NOT_ANSWERABLE + 'Fee terms are not in the CRM record.', no.answer);
        Assert.areEqual(MeetingPrepService.MESSAGE_NOT_ANSWERABLE, no.message);
        Assert.isNull(no.sources);
    }

    // ------------------------------------------------------------------ retry and fallback

    @IsTest
    static void retryThenValidAndRetryThenFallback() {
        ClientContextBuilder.Context c = ctx(SummaryTestData.REFI);
        String good = answerJson(new List<Object>{ sentence('They discussed a 7 versus 10 year tenor.',
            new List<String>{ idOf(c, 'Client_Meeting__c.Meeting_Notes__c:') }) }, null);
        MockLlmGateway mock = useMock(new List<Object>{ 'not json', good, 'not json', '{"answerable": true}' });

        MeetingPrepService.Response ok = askClient(SummaryTestData.REFI, 'What tenor did we discuss?');
        Assert.areEqual(MeetingPrepService.STATUS_ANSWERED, ok.status);
        Assert.areEqual(2, mock.calls);
        Assert.areEqual(2, log(accountId(SummaryTestData.REFI)).Attempts__c);

        MeetingPrepService.Response fb = askClient(SummaryTestData.REFI, 'What tenor did we discuss?');
        Assert.isTrue(fb.success);
        Assert.areEqual(MeetingPrepService.STATUS_FALLBACK, fb.status);
        Assert.areEqual(MeetingPrepService.ANSWER_FALLBACK, fb.answer, 'Never an uncited answer');
        Assert.areEqual(MeetingPrepService.MESSAGE_VALIDATION, fb.message);
        Assert.areEqual('No verified answer because the AI answer did not pass the checks.', fb.reviewItems);
        Assert.isNull(fb.sources);
        AI_Generation_Log__c l = log(accountId(SummaryTestData.REFI));
        Assert.areEqual('Fallback', l.Status__c);
        Assert.areEqual(2, l.Attempts__c);
        Assert.isTrue(l.Validation_Errors__c.startsWith('Error category: VALIDATION\n'), l.Validation_Errors__c);
        Assert.isTrue(l.Raw_Output__c.contains('--- Attempt 2 ---'));
    }

    @IsTest
    static void gatewayErrors() {
        MockLlmGateway mock = useMock(new List<Object>{
            new MockLlmGateway.MockException('Insufficient Privileges: This feature is not currently enabled for this user.'),
            new MockLlmGateway.MockException('Prompt template Meeting_Prep_QA is inactive.'),
            new MockLlmGateway.MockException('Read timed out'), new MockLlmGateway.MockException('503 Service Unavailable') });

        MeetingPrepService.Response perm = askClient(SummaryTestData.REFI, 'What tenor did we discuss?');
        Assert.areEqual(1, mock.calls, 'PERMISSION is not retried');
        Assert.areEqual(MeetingPrepService.MESSAGE_PERMISSION, perm.message);
        Assert.areEqual(MeetingPrepService.STATUS_FALLBACK, perm.status);

        MeetingPrepService.Response config = askClient(SummaryTestData.REFI, 'What tenor did we discuss?');
        Assert.areEqual(2, mock.calls, 'CONFIGURATION is not retried');
        Assert.areEqual(MeetingPrepService.MESSAGE_CONFIGURATION, config.message);

        MeetingPrepService.Response transientError = askClient(SummaryTestData.REFI, 'What tenor did we discuss?');
        Assert.areEqual(4, mock.calls, 'TRANSIENT gets the one retry');
        Assert.areEqual(MeetingPrepService.MESSAGE_TRANSIENT, transientError.message);
        Assert.isTrue(log(accountId(SummaryTestData.REFI)).Validation_Errors__c.startsWith('Error category: TRANSIENT'));
    }

    // ------------------------------------------------------------------ cross-client: mismatch and validator names

    @IsTest
    static void clientMismatchOnlyWhenAnotherClientIsNamedAndTheSelectedIsNot() {
        MockLlmGateway mock = useMock(new List<Object>());

        MeetingPrepService.Response mismatch = askClient(SummaryTestData.HALVERSON, 'What is Northwind\'s leverage target?');
        Assert.areEqual(MeetingPrepService.STATUS_MISMATCH, mismatch.status);
        Assert.areEqual('Your question mentions Northwind Test, but the selected client is Halverson Test. Which client do you mean?',
            mismatch.message);
        Assert.isNull(mismatch.answer);
        AI_Generation_Log__c l = log(accountId(SummaryTestData.HALVERSON));
        Assert.areEqual('Error', l.Status__c);
        Assert.isTrue(l.Validation_Errors__c.startsWith('Error category: CLIENT_MISMATCH'));

        MeetingPrepService.Response deal = askClient(SummaryTestData.HALVERSON, 'How is Keel going?');
        Assert.areEqual(MeetingPrepService.STATUS_MISMATCH, deal.status, 'Another client\'s project code name');
        Assert.isTrue(deal.message.startsWith('Your question mentions Project Keel'), deal.message);
        Assert.areEqual(0, mock.calls, 'No LLM call on a mismatch');

        // The selected client is named too: not a mismatch, the LLM is called.
        ClientContextBuilder.Context n = ctx(SummaryTestData.NORTHWIND);
        useMock(new List<Object>{ answerJson(new List<Object>{ sentence('Henrik Aalto is very keen on Baltic Ferry Lines.',
            new List<String>{ idOf(n, 'Client_Meeting__c.Meeting_Notes__c:') }) }, new List<String>{ SummaryTestData.INJECTION }),
            answerJson(new List<Object>{ sentence('The family split is the issue for Keel.',
            new List<String>{ idOf(n, 'Client_Meeting__c.Meeting_Notes__c:') }) }, new List<String>{ SummaryTestData.INJECTION }) });
        Assert.areNotEqual(MeetingPrepService.STATUS_MISMATCH,
            askClient(SummaryTestData.NORTHWIND, 'What did Northwind say about Baltic Ferry Lines?').status);
        Assert.areNotEqual(MeetingPrepService.STATUS_MISMATCH, askClient(SummaryTestData.NORTHWIND, 'How is Keel going?').status,
            'The selected client\'s own project code name');
        Assert.areEqual(2, ((MockLlmGateway) MeetingPrepService.gateway).calls);
    }

    @IsTest
    static void anAnswerNamingAnotherClientIsBlockedEndToEnd() {
        // Proves the service passes the other visible names to CitationValidator: an empty list would let this through.
        ClientContextBuilder.Context h = ctx(SummaryTestData.HALVERSON);
        String leak = answerJson(new List<Object>{ sentence('The Atlas update had 11 NDAs back, and Northwind is a bidder.',
            new List<String>{ idOf(h, 'Client_Meeting__c.Meeting_Notes__c:') }) }, null);
        MockLlmGateway mock = useMock(new List<Object>{ leak, leak });

        MeetingPrepService.Response res = askClient(SummaryTestData.HALVERSON, 'What happened at the last meeting?');

        Assert.areEqual(2, mock.calls);
        Assert.areEqual(MeetingPrepService.STATUS_FALLBACK, res.status);
        Assert.areEqual(MeetingPrepService.ANSWER_FALLBACK, res.answer);
        String errors = log(accountId(SummaryTestData.HALVERSON)).Validation_Errors__c;
        Assert.isTrue(errors.contains('names "Northwind Test", which belongs to another client'), errors);
        // Same answer without the other client's name passes, so the block is the cross-client check.
        CitationValidator.Result direct = CitationValidator.validate(leak, h);
        Assert.areEqual(CitationValidator.Outcome.VALID, direct.outcome, 'Without the names list the leak would pass: ' + direct.errors);
    }

    // ------------------------------------------------------------------ review items

    @IsTest
    static void amountConflictGoesToReviewItemsAndTheAnswerIsUnchanged() {
        Id northwind = accountId(SummaryTestData.NORTHWIND);
        insert new Client_Meeting__c(Account__c = northwind, Meeting_Date__c = Date.newInstance(2026, 10, 9),
            Meeting_Notes__c = 'Keel check-in. Keel now sized at ~$1.1bn incl. the second branch.');
        Client_Meeting__c m = [SELECT Name FROM Client_Meeting__c WHERE Account__c = :northwind AND Meeting_Date__c = 2026-10-09];
        ClientContextBuilder.Context n = ctx(SummaryTestData.NORTHWIND);
        String newNotes;
        for (String id : n.sourceText.keySet()) {
            if (n.sourceText.get(id).startsWith('Keel check-in')) {
                newNotes = id;
            }
        }
        useMock(new List<Object>{ answerJson(new List<Object>{
            sentence('Keel is now sized at ~$1.1bn including the second branch.', new List<String>{ newNotes }) }, null) });

        MeetingPrepService.Response res = askClient(SummaryTestData.NORTHWIND, 'How big is Keel now?');

        Assert.areEqual(MeetingPrepService.STATUS_REPAIRED, res.status, 'Repaired: the notes\' injection line was added to ignoredInstructions');
        Assert.isTrue(res.answer.startsWith('Keel is now sized at ~$1.1bn including the second branch.'), 'Answer unchanged: ' + res.answer);
        Assert.areEqual('Notes and CRM disagree: ' + m.Name + ' (2026-10-09) notes state ~$1.1bn for Project Keel; CRM amount is '
            + ClientContextBuilder.money(850000000) + '. CRM may be out of date — review the opportunity.\n'
            + AiActionSupport.REVIEW_INSTRUCTION, res.reviewItems);
        Assert.isFalse(res.reviewItems.containsIgnoreCase('ignore previous'), 'Flagged text is not repeated');
    }

    // ------------------------------------------------------------------ inputs, access, limits, drift

    @IsTest
    static void invalidInputsFailWithoutGenerating() {
        MockLlmGateway mock = useMock(new List<Object>());
        String contactId = [SELECT Id FROM Contact LIMIT 1].Id;
        Map<String, MeetingPrepService.Response> paths = new Map<String, MeetingPrepService.Response>{
            'no client' => askId((String) null, 'Anything?'),
            'not an id' => askId('not-an-id', 'Anything?'),
            'wrong object' => askId(contactId, 'Anything?'),
            'no question' => askClient(SummaryTestData.REFI, '  '),
            'too long' => askClient(SummaryTestData.REFI, 'x'.repeat(MeetingPrepService.MAX_QUESTION_CHARS + 1)) };
        Assert.areEqual(MeetingPrepService.MESSAGE_NO_CLIENT, paths.get('no client').message);
        Assert.areEqual(MeetingPrepService.MESSAGE_INVALID_REFERENCE, paths.get('not an id').message);
        Assert.areEqual(MeetingPrepService.MESSAGE_INVALID_REFERENCE, paths.get('wrong object').message);
        Assert.areEqual(MeetingPrepService.MESSAGE_NO_QUESTION, paths.get('no question').message);
        Assert.areEqual(MeetingPrepService.MESSAGE_TOO_LONG, paths.get('too long').message);
        for (MeetingPrepService.Response r : paths.values()) {
            Assert.isFalse(r.success);
            Assert.areEqual(MeetingPrepService.STATUS_FAILED, r.status);
        }
        Assert.areEqual(MeetingPrepService.MESSAGE_NO_CLIENT,
            MeetingPrepService.answer(new List<MeetingPrepService.Request>{ null })[0].message);
        Assert.areEqual(0, mock.calls);
        Assert.areEqual(0, [SELECT COUNT() FROM AI_Generation_Log__c], 'Nothing to log against');
    }

    @IsTest
    static void userWithoutAccessGetsAMessageAndALogRow() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        User noAccess = new User(ProfileId = p.Id, LastName = 'NoAccess', Alias = 'noacc7',
            Username = 'noaccess7' + String.valueOf(Crypto.getRandomInteger()).replace('-', '') + '@example.com.test',
            Email = 'noaccess@example.com', TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        MockLlmGateway mock = useMock(new List<Object>());
        String id = accountId(SummaryTestData.HALVERSON);
        MeetingPrepService.Response res;
        System.runAs(noAccess) {
            res = askId(id, 'Any open deals?');
        }
        Assert.isFalse(res.success);
        Assert.areEqual(MeetingPrepService.MESSAGE_NO_ACCESS, res.message);
        Assert.areEqual(0, mock.calls);
        AI_Generation_Log__c l = log(id);
        Assert.areEqual('Error', l.Status__c, 'Logged in system mode');
        Assert.isTrue(l.Validation_Errors__c.startsWith('Context could not be built'));
    }

    @IsTest
    static void tooManyQuestionsAndContextDrift() {
        ClientContextBuilder.Context c = ctx(SummaryTestData.REFI);
        String good = answerJson(new List<Object>{ sentence('They discussed a 7 versus 10 year tenor.',
            new List<String>{ idOf(c, 'Client_Meeting__c.Meeting_Notes__c:') }) }, null);
        MockLlmGateway mock = useMock(new List<Object>{ good, good });
        mock.resolvedPromptOverride = 'QUESTION...\n' + MockLlmGateway.PREP_CONTEXT_BEGIN + 'a different context' + MockLlmGateway.PREP_CONTEXT_END;

        List<MeetingPrepService.Request> reqs = new List<MeetingPrepService.Request>();
        for (Integer i = 0; i <= MeetingPrepService.MAX_PER_CALL; i++) {
            MeetingPrepService.Request r = new MeetingPrepService.Request();
            r.accountId = accountId(SummaryTestData.REFI);
            r.question = 'What tenor did we discuss?';
            reqs.add(r);
        }
        mock.queue.add(good);
        List<MeetingPrepService.Response> out = MeetingPrepService.answer(reqs);

        Assert.isTrue(out[MeetingPrepService.MAX_PER_CALL].message.startsWith('Too many questions'));
        Assert.areEqual(MeetingPrepService.STATUS_ANSWERED, out[0].status, 'Drift is logged, not fatal');
        Assert.isTrue(log(accountId(SummaryTestData.REFI)).Validation_Errors__c.contains('context drift: the model saw a different context'));

        mock.resolvedPromptOverride = 'no context block here';
        mock.queue.add(good);
        askClient(SummaryTestData.REFI, 'What tenor did we discuss?');
        Assert.isTrue(log(accountId(SummaryTestData.REFI)).Validation_Errors__c.contains('no context block found'));
    }

    @IsTest
    static void messagesAreBankerFacing() {
        for (String c : new List<String>{ MeetingPrepService.ANSWER_FALLBACK, MeetingPrepService.ANSWER_NOT_ANSWERABLE,
                MeetingPrepService.MESSAGE_ANSWERED, MeetingPrepService.MESSAGE_REPAIRED, MeetingPrepService.MESSAGE_NOT_ANSWERABLE,
                MeetingPrepService.MESSAGE_PERMISSION, MeetingPrepService.MESSAGE_CONFIGURATION, MeetingPrepService.MESSAGE_TRANSIENT,
                MeetingPrepService.MESSAGE_VALIDATION, MeetingPrepService.MESSAGE_NO_CLIENT, MeetingPrepService.MESSAGE_INVALID_REFERENCE,
                MeetingPrepService.MESSAGE_NO_QUESTION, MeetingPrepService.MESSAGE_TOO_LONG, MeetingPrepService.MESSAGE_NO_ACCESS,
                MeetingPrepService.REVIEW_FALLBACK }) {
            SummaryTestData.assertBankerFacing(c, 'constant');
        }
        useMock(new List<Object>());
        SummaryTestData.assertBankerFacing(askClient(SummaryTestData.HALVERSON, 'What is Northwind\'s leverage target?').message, 'mismatch');
    }
}
