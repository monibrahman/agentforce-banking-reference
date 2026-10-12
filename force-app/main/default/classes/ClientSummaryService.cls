/**
 * One-click Client Meeting Summary: the one service behind both the Quick Action and the Banker Assistant agent.
 *
 * Flow per meeting (CLAUDE.md > ClientSummaryService):
 *   build context -> generate (template _5) -> validate -> VALID / REPAIRABLE: use it; INVALID or error: one plain retry
 *   -> still INVALID: data-only fallback. Then save fields, attach the PDF, write AI_Generation_Log__c.
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

    static final Integer TEXT_LIMIT = 32768;
    static final Integer SUMMARY_TEXT_LIMIT = 500;

    @TestVisible static ILlmGateway gateway = new PromptTemplateGateway();

    public class Request {
        @InvocableVariable(label='Meeting Id' description='Id of the Client Meeting record to summarize.' required=true)
        public Id meetingId;
    }

    public class Response {
        @InvocableVariable(label='Success' description='True when a summary (AI or data-only fallback) was saved on the meeting.')
        public Boolean success = false;
        @InvocableVariable(label='Status' description='Generated, Generated (Repaired), Fallback (data-only summary) or Failed.')
        public String status;
        @InvocableVariable(label='Summary' description='Short text of the saved summary: the executive summary, or the data-only notice. At most 500 characters.')
        public String summaryText;
        @InvocableVariable(label='File Id' description='ContentDocument Id of the summary PDF attached to the meeting.')
        public String fileId;
        @InvocableVariable(label='Message' description='What happened, in plain language, to show to the banker.')
        public String message;
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
        Boolean save = false;                // true when there is a summary to write to the meeting
    }

    @InvocableMethod(label='Generate Client Meeting Summary'
        description='Generates a structured, source-checked summary of a client meeting from CRM data and the meeting notes, saves it on the meeting record and attaches a PDF. Pass the meeting record Id.')
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

        // Phase B: DML only.
        saveFiles(jobs);
        saveMeetings(jobs);
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
                job.res.message = 'The AI summary did not pass the checks, so a data-only summary from the record was saved instead.';
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
                job.notes.add(label + 'generation failed: ' + e.getMessage());
                continue;
            }
            job.latencyMs += System.currentTimeMillis() - started;
            job.rawOutputs.add(out.text);
            checkDrift(job, out.resolvedPrompt, label);
            SummaryValidator.Result r = SummaryValidator.validate(out.text, job.ctx);
            if (r.outcome == SummaryValidator.Outcome.INVALID) {
                job.notes.add(label + 'invalid: ' + String.join(r.errors, ' | '));
            } else {
                job.result = r;
            }
        }
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

    static void saveFiles(List<Job> jobs) {
        List<ContentVersion> versions = new List<ContentVersion>();
        List<Job> owners = new List<Job>();
        for (Job job : jobs) {
            if (!job.save) {
                continue;
            }
            ContentVersion cv = new ContentVersion(Title = job.meeting.Name + ' summary', PathOnClient = 'ClientMeetingSummary.pdf',
                VersionData = job.pdf);
            if (String.isNotBlank(job.meeting.Summary_File_Id__c)) {
                cv.ContentDocumentId = job.meeting.Summary_File_Id__c;   // new version of the existing file
            } else {
                cv.FirstPublishLocationId = job.meetingId;
            }
            versions.add(cv);
            owners.add(job);
        }
        if (versions.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.insert(versions, false, AccessLevel.USER_MODE);
        List<ContentVersion> retry = new List<ContentVersion>();
        List<Job> retryOwners = new List<Job>();
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess() && versions[i].ContentDocumentId != null) {
                // The old file is gone or not editable by this user: attach a new one instead.
                owners[i].notes.add('Previous summary file not updatable (' + firstError(results[i]) + '); attached a new file.');
                retry.add(new ContentVersion(Title = versions[i].Title, PathOnClient = versions[i].PathOnClient,
                    VersionData = versions[i].VersionData, FirstPublishLocationId = owners[i].meetingId));
                retryOwners.add(owners[i]);
            } else if (!results[i].isSuccess()) {
                owners[i].notes.add('PDF not attached: ' + firstError(results[i]));
            }
        }
        if (!retry.isEmpty()) {
            List<Database.SaveResult> retried = Database.insert(retry, false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < retried.size(); i++) {
                if (!retried[i].isSuccess()) {
                    retryOwners[i].notes.add('PDF not attached: ' + firstError(retried[i]));
                }
            }
            versions.addAll(retry);
        }
        Map<Id, Id> docByVersion = new Map<Id, Id>();
        for (ContentVersion cv : [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :versions WITH USER_MODE]) {
            docByVersion.put(cv.Id, cv.ContentDocumentId);
        }
        for (Integer i = 0; i < owners.size(); i++) {
            Id docId = docByVersion.get(versions[i].Id);
            owners[i].res.fileId = docId == null ? null : String.valueOf(docId);
        }
        for (Integer i = 0; i < retryOwners.size(); i++) {
            Id docId = docByVersion.get(retry[i].Id);
            retryOwners[i].res.fileId = docId == null ? null : String.valueOf(docId);
        }
    }

    static void saveMeetings(List<Job> jobs) {
        List<Client_Meeting__c> updates = new List<Client_Meeting__c>();
        List<Job> owners = new List<Job>();
        for (Job job : jobs) {
            if (!job.save) {
                continue;
            }
            updates.add(new Client_Meeting__c(Id = job.meetingId,
                Summary__c = SummaryRenderer.forField(job.html),
                Summary_JSON__c = job.result == null ? null : job.result.json,
                Summary_Status__c = job.res.status,
                Summary_Generated_At__c = System.now(),
                Summary_File_Id__c = job.res.fileId));
            owners.add(job);
        }
        if (updates.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.update(updates, false, AccessLevel.USER_MODE);
        for (Integer i = 0; i < results.size(); i++) {
            Job job = owners[i];
            if (results[i].isSuccess()) {
                job.res.success = true;
            } else {
                job.notes.add('Meeting not updated: ' + firstError(results[i]));
                fail(job, 'The summary could not be saved on the meeting: ' + firstError(results[i]));
                job.logStatus = 'Error';
            }
        }
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
