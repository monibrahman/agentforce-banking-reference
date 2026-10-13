/**
 * One-click Client Meeting Summary: the one service behind both the Quick Action and the Banker Assistant agent.
 *
 * Flow per meeting (CLAUDE.md > ClientSummaryService):
 *   build context -> generate (template _5) -> validate -> VALID / REPAIRABLE: use it; INVALID or a transient error: one
 *   plain retry -> still failing: data-only fallback. Permission and configuration errors are not retried (same answer every
 *   time); the banker gets a message naming the cause. Then save fields, attach the PDF, write AI_Generation_Log__c.
 *
 * Order matters: Phase A makes every LLM call for every meeting before Phase B does any DML (a generation after DML in
 * the same transaction fails with "uncommitted work pending").
 *
 * Limits: each generation costs our transaction ~5 SOQL and 0.5-0.7 s CPU for the template's grounding Apex (spike,
 * BUILD_LOG 2026-10-12), so at most MAX_PER_CALL meetings are processed per call; the rest get a clear message.
 *
 * Security: the meeting is read and written in USER_MODE (the banker's access). The log is written in SYSTEM_MODE so
 * logging never depends on the banker's permissions; bankers can't read it (OWD Private, AI_Ops permission set only).
 */
public with sharing class ClientSummaryService {

    public static final String TEMPLATE_NAME = 'Client_Meeting_Summary';
    /** The API doesn't return the version that ran. Update this whenever the active template version changes (CLAUDE.md). */
    public static final String TEMPLATE_VERSION = '_5';
    public static final Integer MAX_PER_CALL = 3;
    public static final Integer MAX_ATTEMPTS = 2;   // first try + one plain retry, no validation feedback

    public static final String CONTEXT_BEGIN = '=== CONTEXT (the only facts you may use) ===\n';
    public static final String CONTEXT_END = '\n=== END CONTEXT ===';

    public static final String STATUS_GENERATED = 'Generated';
    public static final String STATUS_REPAIRED = 'Generated (Repaired)';
    public static final String STATUS_FALLBACK = 'Fallback';
    public static final String STATUS_FAILED = 'Failed';

    // Why a run ended in the data-only fallback. Logged as the first line of Validation_Errors__c ("Error category: ...").
    public static final String CATEGORY_PERMISSION = 'PERMISSION';       // user may not run the template: never retried
    public static final String CATEGORY_CONFIGURATION = 'CONFIGURATION'; // template missing or inactive: never retried
    public static final String CATEGORY_TRANSIENT = 'TRANSIENT';         // timeout, service unavailable, anything else: one retry
    public static final String CATEGORY_VALIDATION = 'VALIDATION';       // the model answered but the output failed the checks

    public static final String MESSAGE_PERMISSION = 'AI summaries aren\'t enabled for your user (missing the Prompt Template '
        + 'User permission). A data-only summary was saved. Ask your Salesforce admin for access.';
    public static final String MESSAGE_CONFIGURATION = 'AI summaries aren\'t set up correctly in this org (the '
        + TEMPLATE_NAME + ' prompt template is missing or not active). A data-only summary was saved. Ask your Salesforce admin.';
    public static final String MESSAGE_TRANSIENT = 'The AI service didn\'t respond, so a data-only summary from the record was '
        + 'saved instead. Try again in a few minutes.';
    public static final String MESSAGE_VALIDATION = 'The AI summary did not pass the checks, so a data-only summary from the '
        + 'record was saved instead.';

    // Matched against the exception message, lower case. PERMISSION text is the real one (banker test A, 2026-10-12):
    // "Insufficient Privileges: This feature is not currently enabled for this user." CONFIGURATION texts are not yet seen
    // from the real API; anything unrecognised is treated as TRANSIENT, which only costs one extra call.
    static final List<String> PERMISSION_TEXTS = new List<String>{ 'insufficient privileges', 'not currently enabled for this user',
        'insufficient access', 'do not have access', 'don\'t have access', 'not have permission' };
    static final List<String> CONFIGURATION_TEXTS = new List<String>{ 'template not found', 'no prompt template',
        'not active', 'inactive', 'does not exist', 'invalid prompt template', 'no active version' };

    static final Integer TEXT_LIMIT = 32768;
    static final Integer SUMMARY_TEXT_LIMIT = 500;

    @TestVisible static ILlmGateway gateway = new PromptTemplateGateway();

    // Descriptions are written for the agent's planner as well as admins: the planner reads them to decide what to pass
    // and what to show. summaryText and message are validated output, so the agent must show them exactly as returned.
    public class Request {
        @InvocableVariable(label='Meeting Id'
            description='Salesforce record Id of the Client Meeting to summarize (15 or 18 characters), taken from Find Client Meetings. Never guess or invent it, and do not ask the banker for it: ask for the client, date or meeting name and use Find Client Meetings.'
            required=true)
        public Id meetingId;
    }

    public class Response {
        @InvocableVariable(label='Success' description='True when a summary (AI or data-only fallback) was saved on the meeting. False means nothing was saved; show Message.')
        public Boolean success = false;
        @InvocableVariable(label='Status'
            description='Generated: AI summary, passed all checks. Generated (Repaired): AI summary, code corrected some details (for example a next step\'s owner). Fallback: the AI summary was not available or did not pass the checks, so a data-only summary from CRM was saved. Failed: nothing was saved.')
        public String status;
        @InvocableVariable(label='Summary'
            description='The executive summary of the saved summary, or the data-only notice. Show it to the banker exactly as returned: do not paraphrase, shorten or add facts; this text has been validated. At most 500 characters.')
        public String summaryText;
        @InvocableVariable(label='File Id' description='Internal ContentDocument Id of the summary PDF. Do not show it to the banker; give the Record Link instead.')
        public String fileId;
        @InvocableVariable(label='Message'
            description='What happened, in plain language, for the banker. Show it exactly as returned: do not paraphrase, shorten or add facts; this text has been validated.')
        public String message;
        @InvocableVariable(label='Record Link'
            description='Relative link to the meeting record (/lightning/r/...), where the full summary, its sources and the PDF are. Give it to the banker when a summary was saved. Empty when nothing was saved.')
        public String recordUrl;
    }

    /** Everything known about one meeting's run; filled in Phase A, saved in Phase B. */
    private class Job {
        Id meetingId;
        Response res = new Response();
        ClientContextBuilder.Context ctx;
        Client_Meeting__c meeting;           // Name and current Summary_File_Id__c
        SummaryValidator.Result result;      // the accepted result, or null for fallback
        List<String> rawOutputs = new List<String>();
        List<String> notes = new List<String>();   // validation errors, retries, drift: goes to Validation_Errors__c
        Integer attempts = 0;
        Long latencyMs = 0;
        String html;
        Blob pdf;
        String logStatus;
        String failure;                      // category of the last failed attempt (CATEGORY_*), null if none
        Boolean save = false;                // true when there is a summary to write to the meeting
    }

    @InvocableMethod(label='Generate Client Meeting Summary'
        description='Generates a structured, source-checked summary of one client meeting from CRM data and the meeting notes, saves it on the meeting record and attaches a PDF. Needs the meeting Id from Find Client Meetings; never guess or invent an Id. If Find Client Meetings shows a summary already exists, ask the banker before generating a new one. Takes several seconds. Show the banker Summary and Message exactly as returned (do not paraphrase, shorten or add facts; they have been validated), the Status, and the Record Link to the full summary and PDF. Do not answer questions about the meeting from anything other than this output.')
    public static List<Response> generate(List<Request> requests) {
        List<Job> jobs = new List<Job>();
        List<Response> responses = new List<Response>();
        for (Integer i = 0; i < requests.size(); i++) {
            Job job = new Job();
            job.meetingId = requests[i] == null ? null : requests[i].meetingId;
            responses.add(job.res);
            if (i >= MAX_PER_CALL) {
                fail(job, 'Too many meetings in one request (max ' + MAX_PER_CALL + '); run again for the rest.');
                continue;
            }
            jobs.add(job);
        }

        // Phase A: no DML. Context, generations (with the retry), validation, rendering.
        for (Job job : jobs) {
            prepare(job);
        }

        // Phase B: DML only. Each meeting is saved under its own savepoint, so a failure rolls back only that meeting's PDF;
        // the log rows are written last and are never rolled back.
        for (Job job : jobs) {
            if (job.save) {
                save(job);
            }
        }
        writeLogs(jobs);
        return responses;
    }

    // ------------------------------------------------------------------------------------------------ Phase A

    static void prepare(Job job) {
        if (job.meetingId == null) {
            fail(job, 'Meeting Id is required.');
            return;
        }
        try {
            job.ctx = ClientContextBuilder.buildContext(job.meetingId);
            job.meeting = [SELECT Id, Name, Summary_File_Id__c FROM Client_Meeting__c WHERE Id = :job.meetingId WITH USER_MODE];
        } catch (Exception e) {
            // ContextException (not found) or QueryException (no access under USER_MODE). No generation happens.
            fail(job, 'You don\'t have access to this meeting, or it no longer exists.');
            job.notes.add('Context could not be built: ' + e.getMessage());
            job.logStatus = 'Error';
            return;
        }
        try {
            generateWithRetry(job);
            if (job.result == null) {
                job.html = SummaryRenderer.fallbackHtml(job.ctx);
                job.logStatus = STATUS_FALLBACK;
                job.res.status = STATUS_FALLBACK;
                job.res.summaryText = SummaryRenderer.FALLBACK_BANNER;
                job.res.message = fallbackMessage(job.failure);
                job.notes.add(0, 'Error category: ' + job.failure);
            } else {
                Boolean repaired = job.result.outcome == SummaryValidator.Outcome.REPAIRABLE;
                job.html = SummaryRenderer.toHtml(job.result.summary, job.ctx);
                job.logStatus = repaired ? 'Repaired' : 'Valid';
                job.res.status = repaired ? STATUS_REPAIRED : STATUS_GENERATED;
                job.res.summaryText = String.valueOf(job.result.summary.get('executiveSummary')).abbreviate(SUMMARY_TEXT_LIMIT);
                job.res.message = 'Summary generated and saved' + (repaired ? '; code corrected some details (see the log).' : '.');
                if (repaired) {
                    job.notes.add('Repairs: ' + String.join(job.result.repairs, ' | '));
                }
            }
            job.pdf = SummaryRenderer.toPdf(job.html);
            job.save = true;
        } catch (Exception e) {
            fail(job, 'The summary could not be produced: ' + e.getMessage());
            job.notes.add('Unexpected error: ' + e.getTypeName() + ': ' + e.getMessage());
            job.logStatus = 'Error';
        }
    }

    /**
     * First try + one plain retry. Only TRANSIENT errors and invalid output are retried: a PERMISSION or CONFIGURATION error
     * gives the same answer every time, so it stops after one attempt.
     */
    static void generateWithRetry(Job job) {
        while (job.result == null && job.attempts < MAX_ATTEMPTS) {
            job.attempts++;
            String label = 'Attempt ' + job.attempts + ': ';
            Long started = System.currentTimeMillis();
            LlmResponse out;
            try {
                out = gateway.generate(TEMPLATE_NAME, job.meetingId);
            } catch (Exception e) {
                job.latencyMs += System.currentTimeMillis() - started;
                job.rawOutputs.add('(no output)');
                job.failure = classify(e);
                job.notes.add(label + 'generation failed (' + job.failure + ', ' + e.getTypeName() + '): ' + e.getMessage());
                if (job.failure != CATEGORY_TRANSIENT) {
                    break;
                }
                continue;
            }
            job.latencyMs += System.currentTimeMillis() - started;
            job.rawOutputs.add(out.text);
            checkDrift(job, out.resolvedPrompt, label);
            SummaryValidator.Result r = SummaryValidator.validate(out.text, job.ctx);
            if (r.outcome == SummaryValidator.Outcome.INVALID) {
                job.failure = CATEGORY_VALIDATION;
                job.notes.add(label + 'invalid: ' + String.join(r.errors, ' | '));
            } else {
                job.result = r;
            }
        }
    }

    /** PERMISSION, CONFIGURATION or TRANSIENT, from the exception type and message. */
    @TestVisible
    static String classify(Exception e) {
        if (e instanceof NoAccessException) {
            return CATEGORY_PERMISSION;
        }
        String text = String.valueOf(e.getMessage()).toLowerCase();
        for (String t : PERMISSION_TEXTS) {
            if (text.contains(t)) {
                return CATEGORY_PERMISSION;
            }
        }
        for (String t : CONFIGURATION_TEXTS) {
            if (text.contains(t)) {
                return CATEGORY_CONFIGURATION;
            }
        }
        return CATEGORY_TRANSIENT;
    }

    static String fallbackMessage(String failure) {
        if (failure == CATEGORY_PERMISSION) {
            return MESSAGE_PERMISSION;
        }
        if (failure == CATEGORY_CONFIGURATION) {
            return MESSAGE_CONFIGURATION;
        }
        return failure == CATEGORY_TRANSIENT ? MESSAGE_TRANSIENT : MESSAGE_VALIDATION;
    }

    /** Compares the CONTEXT block the model saw with the context we validate against. Drift is logged, not fatal. */
    static void checkDrift(Job job, String resolvedPrompt, String label) {
        if (resolvedPrompt == null) {
            job.notes.add(label + 'resolved prompt not returned; validated against the rebuilt context.');
            return;
        }
        String seen = resolvedPrompt.substringBetween(CONTEXT_BEGIN, CONTEXT_END);
        if (seen == null) {
            job.notes.add(label + 'context drift: no CONTEXT block found in the resolved prompt.');
        } else if (!seen.equals(job.ctx.text)) {
            job.notes.add(label + 'context drift: the model saw a different context (' + seen.length()
                + ' chars) than the one validated against (' + job.ctx.text.length() + ' chars).');
        }
    }

    // ------------------------------------------------------------------------------------------------ Phase B

    /**
     * Saves one meeting: attach the PDF, then update the meeting with the file id. Runs under its own savepoint, so if the
     * meeting update fails the PDF is rolled back too (no orphan file); the banker gets Failed and the log row says Error.
     */
    static void save(Job job) {
        Savepoint sp = Database.setSavepoint();
        String fileError = attachPdf(job);
        if (fileError != null) {
            job.notes.add('PDF not attached: ' + fileError);
        }
        Database.SaveResult updated = Database.update(new Client_Meeting__c(Id = job.meetingId,
            Summary__c = SummaryRenderer.forField(job.html),
            Summary_JSON__c = job.result == null ? null : job.result.json,
            Summary_Status__c = job.res.status,
            Summary_Generated_At__c = System.now(),
            Summary_File_Id__c = job.res.fileId), false, AccessLevel.USER_MODE);
        if (updated.isSuccess()) {
            job.res.success = true;
            job.res.recordUrl = '/lightning/r/Client_Meeting__c/' + job.meetingId + '/view';
            return;
        }
        Database.rollback(sp);
        job.notes.add('Meeting not updated: ' + firstError(updated) + '; the PDF was rolled back.');
        fail(job, 'The summary could not be saved on the meeting: ' + firstError(updated));
        job.res.fileId = null;
        job.logStatus = 'Error';
    }

    /** Adds the PDF as a new version of the meeting's summary file, or as a new file. Returns an error message or null. */
    static String attachPdf(Job job) {
        ContentVersion cv = newVersion(job);
        Database.SaveResult r;
        if (String.isNotBlank(job.meeting.Summary_File_Id__c)) {
            cv.ContentDocumentId = job.meeting.Summary_File_Id__c;   // new version of the existing file
            r = Database.insert(cv, false, AccessLevel.USER_MODE);
            if (!r.isSuccess()) {
                // The old file is gone or not editable by this user: attach a new one instead.
                job.notes.add('Previous summary file not updatable (' + firstError(r) + '); attached a new file.');
                cv = newVersion(job);
            }
        }
        if (cv.ContentDocumentId == null || !r.isSuccess()) {
            cv.FirstPublishLocationId = job.meetingId;
            r = Database.insert(cv, false, AccessLevel.USER_MODE);
        }
        if (!r.isSuccess()) {
            return firstError(r);
        }
        job.res.fileId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :r.getId() WITH USER_MODE].ContentDocumentId;
        return null;
    }

    static ContentVersion newVersion(Job job) {
        return new ContentVersion(Title = job.meeting.Name + ' summary', PathOnClient = 'ClientMeetingSummary.pdf',
            VersionData = job.pdf);
    }

    static void writeLogs(List<Job> jobs) {
        List<AI_Generation_Log__c> logs = new List<AI_Generation_Log__c>();
        for (Job job : jobs) {
            if (job.meetingId == null) {
                continue;
            }
            logs.add(new AI_Generation_Log__c(
                Record_Id__c = job.meetingId,
                Capability__c = 'Client Summary',
                Template_Name__c = TEMPLATE_NAME,
                Template_Version__c = TEMPLATE_VERSION,
                Status__c = job.logStatus,
                Attempts__c = job.attempts,
                Validation_Errors__c = cap(String.join(job.notes, '\n')),
                Latency_Ms__c = job.latencyMs,
                Context_Chars__c = job.ctx == null ? null : job.ctx.chars,
                Raw_Output__c = cap(rawOutputText(job))));
        }
        // System mode on purpose: observability must not depend on the banker's permissions (see class comment).
        Database.insert(logs, false, AccessLevel.SYSTEM_MODE);
    }

    // ------------------------------------------------------------------------------------------------ helpers

    static void fail(Job job, String message) {
        job.res.success = false;
        job.res.status = STATUS_FAILED;
        job.res.message = message;
        job.save = false;
    }

    static String rawOutputText(Job job) {
        List<String> parts = new List<String>();
        for (Integer i = 0; i < job.rawOutputs.size(); i++) {
            parts.add('--- Attempt ' + (i + 1) + ' ---\n' + job.rawOutputs[i]);
        }
        return String.join(parts, '\n');
    }

    static String cap(String s) {
        return String.isBlank(s) ? null : s.abbreviate(TEXT_LIMIT);
    }

    static String firstError(Database.SaveResult r) {
        return r.getErrors().isEmpty() ? 'unknown error' : r.getErrors()[0].getMessage();
    }
}
