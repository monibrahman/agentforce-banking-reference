/**
 * Meeting Prep Q&A (Option B): answers a banker's question about one client from the CRM record, with every sentence
 * checked against the sources it cites. Same pattern as ClientSummaryService (Context -> Template -> Validate ->
 * Fallback -> Log) and the same shared plumbing (AiActionSupport).
 *
 * Per question:
 *   1. Inputs: accountId must be an Account Id (the agent binds it to selected_account_id from Find Client; there is no
 *      meetingId input on purpose, so another client's meeting can't select its account). Question required, max 500.
 *   2. Context: ClientContextBuilder.buildAccountContext, USER_MODE (the banker's access).
 *   3. Other visible names (USER_MODE): other accounts and other clients' open deals. Used twice: the client mismatch
 *      check below, and CitationValidator's other-client check (an empty list would silently disable it).
 *   4. Client mismatch (no LLM call): the question names another visible client or deal and not the selected client.
 *   5. Generate (Meeting_Prep_QA, inputs Account + Question verbatim) -> CitationValidator; one plain retry for invalid
 *      output or TRANSIENT errors; PERMISSION/CONFIGURATION not retried; then a message-only fallback (never an uncited
 *      answer, D7).
 *   6. Render: sentences with readable source labels ("[Meeting MTG-0014, 2026-10-08]"), one plain "label: https://..."
 *      line per cited record (links from code), Review Items (amount conflicts across all recent meetings' notes, flagged
 *      instructions). Then AI_Generation_Log__c rows (system mode), after every LLM call.
 *
 * Writes no records except the log, so there is no PDF or savepoint here.
 */
public with sharing class MeetingPrepService {

    public static final String TEMPLATE_NAME = 'Meeting_Prep_QA';
    /** The API doesn't return the version that ran. Update this whenever the active template version changes (CLAUDE.md). */
    public static final String TEMPLATE_VERSION = '_2';
    public static final String CAPABILITY = 'Meeting Prep';
    public static final Integer MAX_PER_CALL = 3;
    public static final Integer MAX_ATTEMPTS = 2;          // first try + one plain retry, no validation feedback
    public static final Integer MAX_QUESTION_CHARS = 500;
    static final Integer MAX_OTHER_NAMES = 2000;            // other visible accounts/deals for the cross-client checks

    public static final String STATUS_ANSWERED = 'Answered';
    public static final String STATUS_REPAIRED = 'Answered (Repaired)';
    public static final String STATUS_NOT_ANSWERABLE = 'Not answerable';
    public static final String STATUS_MISMATCH = 'Client mismatch';
    public static final String STATUS_FALLBACK = 'Fallback';
    public static final String STATUS_FAILED = 'Failed';

    // Banker-facing text, shown verbatim (CLAUDE.md rule: written to the banker, never about them).
    public static final String ANSWER_FALLBACK = 'I couldn\'t produce a verified answer to that question from the CRM record.';
    public static final String ANSWER_NOT_ANSWERABLE = 'I can\'t answer that from the CRM record. Missing: ';
    public static final String MESSAGE_ANSWERED = 'Answer checked against the CRM record.';
    public static final String MESSAGE_REPAIRED = 'Answer checked against the CRM record; some details were corrected automatically by validation checks.';
    public static final String MESSAGE_NOT_ANSWERABLE = 'The CRM record doesn\'t contain the answer.';
    public static final String MESSAGE_PERMISSION = 'AI answers aren\'t enabled for your user (missing the Prompt Template User permission). '
        + 'Ask your Salesforce admin for access.';
    public static final String MESSAGE_CONFIGURATION = 'AI answers aren\'t set up correctly in this org (the ' + TEMPLATE_NAME
        + ' prompt template is missing or not active). Ask your Salesforce admin.';
    public static final String MESSAGE_TRANSIENT = 'The AI service didn\'t respond. Try again in a few minutes.';
    public static final String MESSAGE_VALIDATION = 'The AI answer did not pass the checks, so no answer is shown.';
    public static final String MESSAGE_NO_CLIENT = 'No client was selected. Tell me the client name.';
    public static final String MESSAGE_INVALID_REFERENCE = 'That isn\'t a valid client reference.';
    public static final String MESSAGE_NO_QUESTION = 'No question was given. Ask me a question about the client.';
    public static final String MESSAGE_TOO_LONG = 'That question is too long (max ' + MAX_QUESTION_CHARS + ' characters). Please shorten it.';
    public static final String MESSAGE_NO_ACCESS = 'You don\'t have access to this client, or it no longer exists.';
    public static final String REVIEW_FALLBACK = 'No verified answer because ';
    static final Map<String, String> FALLBACK_REASONS = new Map<String, String>{
        AiActionSupport.CATEGORY_PERMISSION => 'AI answers aren\'t enabled for your user (missing the Prompt Template User permission).',
        AiActionSupport.CATEGORY_CONFIGURATION => 'the ' + TEMPLATE_NAME + ' prompt template is missing or not active.',
        AiActionSupport.CATEGORY_TRANSIENT => 'the AI service didn\'t respond.',
        AiActionSupport.CATEGORY_VALIDATION => 'the AI answer did not pass the checks.' };

    @TestVisible static ILlmGateway gateway = new PromptTemplateGateway();

    public class Request {
        // Text, not Id: Agent Builder binds a Text agent variable (selected_account_id) to it. Checked in code.
        @InvocableVariable(label='Client Id'
            description='Salesforce record Id of the client (Account), taken from Find Client (Selected Client Id). Never guess or invent it, and do not ask the banker for it: ask for the client name and use Find Client.'
            required=true)
        public String accountId;

        @InvocableVariable(label='Question'
            description='The banker\'s question about this client, exactly as asked. Do not rephrase, shorten or add to it. Max 500 characters.'
            required=true)
        public String question;
    }

    public class Response {
        @InvocableVariable(label='Success' description='True when the question was processed (answered, not answerable, or a fallback message). False means nothing was answered; show Message.')
        public Boolean success = false;
        @InvocableVariable(label='Status'
            description='Answered: every sentence checked against its cited sources. Answered (Repaired): checked, code corrected small details. Not answerable: the CRM record does not contain the answer. Client mismatch: the question names another client; ask which client. Fallback: no verified answer could be produced. Failed: nothing was processed.')
        public String status;
        @InvocableVariable(label='Answer'
            description='The answer, each sentence followed by the records it comes from in brackets, or the not-answerable / fallback text. Show it to the banker exactly as returned: do not paraphrase, shorten or add facts; this text has been validated.')
        public String answer;
        @InvocableVariable(label='Sources'
            description='One line per cited record: "<record>: https://...". Show it exactly as returned, each link on its own line; never write, rebuild or change a URL.')
        public String sources;
        @InvocableVariable(label='Review Items'
            description='What the banker should review: where meeting notes and CRM amounts disagree, notes text addressed to the AI that was flagged, and why no verified answer was produced. Empty when there is nothing to review. Show it exactly as returned.')
        public String reviewItems;
        @InvocableVariable(label='Message'
            description='What happened, in plain language, for the banker. Show it exactly as returned: do not paraphrase, shorten or add facts.')
        public String message;
    }

    private class Job {
        Id accountId;
        String question;
        Response res = new Response();
        ClientContextBuilder.Context ctx;
        Set<String> otherNames = new Set<String>();
        CitationValidator.Result result;
        List<String> rawOutputs = new List<String>();
        List<String> notes = new List<String>();
        Integer attempts = 0;
        Long latencyMs = 0;
        String logStatus;
        String failure;
        Boolean log = false;
    }

    @InvocableMethod(label='Answer Client Question'
        description='Answers a banker\'s question about one client from the CRM record (open deals, the 3 most recent meetings and their notes, research notes, contacts, recent activity). Every sentence is checked against the records it cites; if the record does not contain the answer, it says so. Needs the Client Id from Find Client (Selected Client Id); never guess it. Pass the banker\'s question exactly as asked. Show Answer, Sources, Review Items and Message exactly as returned (they have been validated), each link on its own line. Never write, rebuild or change a URL, and never answer client questions from earlier conversation or from memory.')
    public static List<Response> answer(List<Request> requests) {
        List<Job> jobs = new List<Job>();
        List<Response> responses = new List<Response>();
        for (Integer i = 0; i < requests.size(); i++) {
            Job job = new Job();
            responses.add(job.res);
            if (i >= MAX_PER_CALL) {
                fail(job, 'Too many questions in one request (max ' + MAX_PER_CALL + '); ask the rest separately.');
                continue;
            }
            if (checkInputs(requests[i], job)) {
                jobs.add(job);
            }
        }
        // All LLM calls first; the only DML (log rows) comes after.
        for (Job job : jobs) {
            prepare(job);
        }
        writeLogs(jobs);
        return responses;
    }

    // ------------------------------------------------------------------------------------------------ inputs

    static Boolean checkInputs(Request req, Job job) {
        String raw = req == null ? null : req.accountId?.trim();
        String question = req == null ? null : req.question?.trim();
        if (String.isBlank(raw)) {
            fail(job, MESSAGE_NO_CLIENT);
            return false;
        }
        job.accountId = AiActionSupport.validId(raw, Account.SObjectType);
        if (job.accountId == null) {
            fail(job, MESSAGE_INVALID_REFERENCE);   // not logged: there is no client to log against
            return false;
        }
        if (String.isBlank(question)) {
            fail(job, MESSAGE_NO_QUESTION);
            return false;
        }
        if (question.length() > MAX_QUESTION_CHARS) {
            fail(job, MESSAGE_TOO_LONG);
            return false;
        }
        job.question = question;
        return true;
    }

    // ------------------------------------------------------------------------------------------------ no DML

    static void prepare(Job job) {
        job.log = true;
        String clientName;
        try {
            job.ctx = ClientContextBuilder.buildAccountContext(job.accountId);
            clientName = [SELECT Name FROM Account WHERE Id = :job.accountId WITH USER_MODE].Name;
            loadOtherNames(job);
        } catch (Exception e) {
            // ContextException (not found) or QueryException (no access under USER_MODE). No generation happens.
            fail(job, MESSAGE_NO_ACCESS);
            job.notes.add('Context could not be built: ' + e.getMessage());
            job.logStatus = 'Error';
            return;
        }

        String mismatch = mismatchedName(job.question, clientName, job.ctx, job.otherNames);
        if (mismatch != null) {
            job.res.status = STATUS_MISMATCH;
            job.res.success = true;
            job.res.message = 'Your question mentions ' + mismatch + ', but the selected client is ' + clientName
                + '. Which client do you mean?';
            job.notes.add('Error category: CLIENT_MISMATCH');
            job.notes.add('Question names "' + mismatch + '", not the selected client; no generation.');
            job.logStatus = 'Error';
            return;
        }

        try {
            generateWithRetry(job);
        } catch (Exception e) {
            fail(job, 'The question could not be answered: ' + e.getMessage());
            job.notes.add('Unexpected error: ' + e.getTypeName() + ': ' + e.getMessage());
            job.logStatus = 'Error';
            return;
        }
        render(job);
    }

    /** Other accounts and other clients' open deals the banker can see (USER_MODE). */
    static void loadOtherNames(Job job) {
        for (Account a : [SELECT Name FROM Account WHERE Id != :job.accountId WITH USER_MODE ORDER BY Name LIMIT :MAX_OTHER_NAMES]) {
            job.otherNames.add(a.Name);
        }
        for (Opportunity o : [SELECT Name FROM Opportunity WHERE AccountId != :job.accountId AND IsClosed = false
                              WITH USER_MODE ORDER BY Name LIMIT :MAX_OTHER_NAMES]) {
            job.otherNames.add(o.Name);
        }
    }

    /**
     * A mismatch only when the question names another visible client or deal AND does not name the selected client (its
     * name or one of its project code names). "What did Northwind say about Baltic Ferry Lines?" with Northwind selected
     * is not a mismatch.
     */
    @TestVisible
    static String mismatchedName(String question, String clientName, ClientContextBuilder.Context ctx, Set<String> otherNames) {
        List<String> others = CitationValidator.namesMentioned(question, otherNames, true);   // proper-noun use only
        if (others.isEmpty()) {
            return null;
        }
        Set<String> selected = new Set<String>{ clientName };
        for (ClientContextBuilder.ContextSection sec : ctx.sections) {
            if (sec.title == 'OPEN OPPORTUNITIES') {
                for (ClientContextBuilder.ContextLine l : sec.lines) {
                    if (CitationValidator.projectCodeName(l.name) != null) {
                        selected.add(l.name);
                    }
                }
            }
        }
        return CitationValidator.namesMentioned(question, selected, false).isEmpty() ? others[0] : null;
    }

    static void generateWithRetry(Job job) {
        Map<String, Object> inputs = new Map<String, Object>{ 'Input:Account' => job.accountId, 'Input:Question' => job.question };
        while (job.result == null && job.attempts < MAX_ATTEMPTS) {
            job.attempts++;
            String label = 'Attempt ' + job.attempts + ': ';
            Long started = System.currentTimeMillis();
            LlmResponse out;
            try {
                out = gateway.generate(TEMPLATE_NAME, inputs);
            } catch (Exception e) {
                job.latencyMs += System.currentTimeMillis() - started;
                job.rawOutputs.add('(no output)');
                job.failure = AiActionSupport.classify(e);
                job.notes.add(label + 'generation failed (' + job.failure + ', ' + e.getTypeName() + '): ' + e.getMessage());
                if (job.failure != AiActionSupport.CATEGORY_TRANSIENT) {
                    break;
                }
                continue;
            }
            job.latencyMs += System.currentTimeMillis() - started;
            job.rawOutputs.add(out.text);
            checkDrift(job, out.resolvedPrompt, label);
            CitationValidator.Result r = CitationValidator.validate(out.text, job.ctx, job.otherNames);
            if (r.outcome == CitationValidator.Outcome.INVALID) {
                job.failure = AiActionSupport.CATEGORY_VALIDATION;
                job.notes.add(label + 'invalid: ' + String.join(r.errors, ' | '));
            } else {
                job.result = r;
            }
        }
    }

    static final String PROMPT_CONTEXT_BEGIN = '(every fact has a source id in brackets, e.g. [S3]):\n';
    static final String PROMPT_CONTEXT_END = '\n\nRules:';

    /** Compares the context block in the resolved prompt with the context we validate against. Logged, not fatal. */
    static void checkDrift(Job job, String resolvedPrompt, String label) {
        if (resolvedPrompt == null) {
            job.notes.add(label + 'resolved prompt not returned; validated against the rebuilt context.');
            return;
        }
        String seen = resolvedPrompt.substringBetween(PROMPT_CONTEXT_BEGIN, PROMPT_CONTEXT_END);
        if (seen == null) {
            job.notes.add(label + 'context drift: no context block found in the resolved prompt.');
        } else if (!seen.equals(job.ctx.text)) {
            job.notes.add(label + 'context drift: the model saw a different context (' + seen.length()
                + ' chars) than the one validated against (' + job.ctx.text.length() + ' chars).');
        }
    }

    // ------------------------------------------------------------------------------------------------ render

    static void render(Job job) {
        job.res.success = true;
        // Deterministic: flagged from the context itself, not from the model's ignoredInstructions (v4 run 1, BA-19 vs BA-16).
        Boolean flagged = CitationValidator.contextHasInjection(job.ctx);
        if (job.result == null) {
            job.res.status = STATUS_FALLBACK;
            job.res.answer = ANSWER_FALLBACK;
            job.res.message = fallbackMessage(job.failure);
            job.res.reviewItems = REVIEW_FALLBACK + FALLBACK_REASONS.get(job.failure)
                + (flagged ? '\n' + AiActionSupport.REVIEW_INSTRUCTION : '');
            job.notes.add(0, 'Error category: ' + job.failure);
            job.logStatus = 'Fallback';
            return;
        }
        Map<String, Object> a = job.result.answer;
        Boolean repaired = job.result.outcome == CitationValidator.Outcome.REPAIRABLE;
        job.logStatus = repaired ? 'Repaired' : 'Valid';
        if (repaired) {
            job.notes.add('Repairs: ' + String.join(job.result.repairs, ' | '));
        }
        List<String> review = CitationValidator.amountConflictReviewItems(job.ctx);
        if (flagged) {
            review.add(AiActionSupport.REVIEW_INSTRUCTION);
        }
        job.res.reviewItems = review.isEmpty() ? null : String.join(review, '\n');

        if (!(Boolean) a.get('answerable')) {
            List<String> missing = new List<String>();
            for (Object m : (List<Object>) a.get('missing')) {
                missing.add((String) m);
            }
            job.res.status = STATUS_NOT_ANSWERABLE;
            job.res.answer = ANSWER_NOT_ANSWERABLE + String.join(missing, ' ');
            job.res.message = MESSAGE_NOT_ANSWERABLE;
            job.notes.add('Not answerable.');
            return;
        }
        Map<String, String> labels = new Map<String, String>();
        Map<String, String> links = new Map<String, String>();   // record key -> "label: url", in first-cited order
        List<String> sentences = new List<String>();
        for (Object o : (List<Object>) a.get('sentences')) {
            Map<String, Object> s = (Map<String, Object>) o;
            List<String> sentenceLabels = new List<String>();
            for (Object id : (List<Object>) s.get('sources')) {
                Source src = source((String) id, job.ctx);
                if (!sentenceLabels.contains(src.label)) {
                    sentenceLabels.add(src.label);
                }
                if (!links.containsKey(src.recordKey)) {
                    links.put(src.recordKey, src.label + ': ' + AiActionSupport.recordUrl(src.objectApiName, src.recordId));
                }
            }
            sentences.add(s.get('text') + ' [' + String.join(sentenceLabels, '; ') + ']');
        }
        job.res.status = repaired ? STATUS_REPAIRED : STATUS_ANSWERED;
        job.res.answer = String.join(sentences, '\n');
        job.res.sources = String.join(links.values(), '\n');
        job.res.message = repaired ? MESSAGE_REPAIRED : MESSAGE_ANSWERED;
    }

    private class Source {
        String label;
        String objectApiName;
        Id recordId;
        String recordKey;
    }

    /**
     * A readable label and the record behind a source id: notes and their meeting share "Meeting MTG-0014, 2026-10-08";
     * research body and line share "Research note: <title>, <date>".
     */
    static Source source(String sourceId, ClientContextBuilder.Context ctx) {   // not "id": it would shadow the Id type
        String ref = ctx.sources.get(sourceId);
        Source s = new Source();
        String type = ref.substringBefore(':');
        s.recordId = Id.valueOf(ref.substringAfterLast(':'));
        s.objectApiName = type.substringBefore('.');
        s.recordKey = s.objectApiName + ':' + s.recordId;
        ClientContextBuilder.ContextLine line = lineFor(s.objectApiName + ':' + s.recordId, ctx);
        String name = line == null ? null : line.name;
        String day = line == null ? '' : line.body.substringAfter('Date: ').substringBefore(' |');
        if (s.objectApiName == 'Client_Meeting__c') {
            s.label = 'Meeting ' + name + (String.isBlank(day) ? '' : ', ' + day);
        } else if (s.objectApiName == 'Research_Note__c') {
            String published = line == null ? '' : line.body.substringAfter('Published: ').substringBefore(' |');
            s.label = 'Research note: ' + name + (String.isBlank(published) ? '' : ', ' + published);
        } else if (s.objectApiName == 'Account') {
            s.label = 'Client record: ' + name;
        } else if (s.objectApiName == 'Task' || s.objectApiName == 'Event') {
            s.label = 'Activity: ' + name;
        } else {
            s.label = s.objectApiName + ': ' + name;
        }
        return s;
    }

    static ClientContextBuilder.ContextLine lineFor(String ref, ClientContextBuilder.Context ctx) {
        for (ClientContextBuilder.ContextSection sec : ctx.sections) {
            for (ClientContextBuilder.ContextLine l : sec.lines) {
                if (ref.equals(ctx.sources.get(l.id))) {
                    return l;
                }
            }
        }
        return null;
    }

    // ------------------------------------------------------------------------------------------------ helpers

    static String fallbackMessage(String failure) {
        if (failure == AiActionSupport.CATEGORY_PERMISSION) {
            return MESSAGE_PERMISSION;
        }
        if (failure == AiActionSupport.CATEGORY_CONFIGURATION) {
            return MESSAGE_CONFIGURATION;
        }
        return failure == AiActionSupport.CATEGORY_TRANSIENT ? MESSAGE_TRANSIENT : MESSAGE_VALIDATION;
    }

    static void fail(Job job, String message) {
        job.res.success = false;
        job.res.status = STATUS_FAILED;
        job.res.message = message;
    }

    static void writeLogs(List<Job> jobs) {
        List<AI_Generation_Log__c> logs = new List<AI_Generation_Log__c>();
        for (Job job : jobs) {
            if (job.log) {
                logs.add(AiActionSupport.logRow(job.accountId, CAPABILITY, TEMPLATE_NAME, TEMPLATE_VERSION, job.logStatus,
                    job.attempts, job.notes, job.latencyMs, job.ctx == null ? null : job.ctx.chars, job.rawOutputs));
            }
        }
        AiActionSupport.insertLogs(logs);
    }
}
