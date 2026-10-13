/**
 * Shared plumbing for the AI actions (Context -> Template -> Validate -> Fallback -> Log): ClientSummaryService (Option A)
 * and MeetingPrepService (Option B). Only behaviour that is the same for every action lives here: gateway error
 * classification, input Id checks, code-built record links, text cutting, Review Items prefixes, and AI_Generation_Log__c
 * rows. Action-specific text (messages, statuses, fallback reasons) stays in each service.
 *
 * Extracted from ClientSummaryService without behaviour change (Day 4 step 5a; Option A's tests and BA-23 guard it).
 */
public with sharing class AiActionSupport {

    // ------------------------------------------------------------------------------------------------ gateway errors

    // Why a run ended without a validated answer. Logged as the first line of Validation_Errors__c ("Error category: ...").
    public static final String CATEGORY_PERMISSION = 'PERMISSION';       // user may not run the template: never retried
    public static final String CATEGORY_CONFIGURATION = 'CONFIGURATION'; // template missing or inactive: never retried
    public static final String CATEGORY_TRANSIENT = 'TRANSIENT';         // timeout, service unavailable, anything else: one retry
    public static final String CATEGORY_VALIDATION = 'VALIDATION';       // the model answered but the output failed the checks

    // Matched against the exception message, lower case. PERMISSION text is the real one (banker test A, 2026-10-12):
    // "Insufficient Privileges: This feature is not currently enabled for this user." CONFIGURATION texts are not yet seen
    // from the real API; anything unrecognised is treated as TRANSIENT, which only costs one extra call.
    static final List<String> PERMISSION_TEXTS = new List<String>{ 'insufficient privileges', 'not currently enabled for this user',
        'insufficient access', 'do not have access', 'don\'t have access', 'not have permission' };
    static final List<String> CONFIGURATION_TEXTS = new List<String>{ 'template not found', 'no prompt template',
        'not active', 'inactive', 'does not exist', 'invalid prompt template', 'no active version' };

    /** PERMISSION, CONFIGURATION or TRANSIENT, from the exception type and message. */
    public static String classify(Exception e) {
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

    // ------------------------------------------------------------------------------------------------ inputs and links

    /** The text as an Id of the given object, or null if it is blank, isn't a valid Id, or is an Id of another object. */
    public static Id validId(String raw, Schema.SObjectType expected) {
        if (String.isBlank(raw)) {
            return null;                   // Id.valueOf(null) throws; callers get null like any other bad input
        }
        try {
            Id parsed = Id.valueOf(raw);
            return parsed.getSObjectType() == expected ? parsed : null;
        } catch (StringException e) {
            return null;                   // "Invalid id: ..."
        }
    }

    /** Absolute link to a record, so it is clickable in the agent chat, Slack or email, not only inside Lightning. */
    public static String recordUrl(String objectApiName, Id recordId) {
        return URL.getOrgDomainUrl().toExternalForm() + '/lightning/r/' + objectApiName + '/' + recordId + '/view';
    }

    /**
     * "Open MTG-0019: https://..." as plain text. Action outputs render as plain text in the agent panel and Preview, so
     * markdown links never became clickable, and a bare https URL is what the chat can link. Built in code so the URL
     * always belongs to this record; in run 2 the agent's own reply invented a link with another meeting's Id.
     */
    public static String openLine(String label, String objectApiName, Id recordId) {
        return 'Open ' + label + ': ' + recordUrl(objectApiName, recordId);
    }

    // ------------------------------------------------------------------------------------------------ text

    // Review Items lines (agent chat): what the banker should look at, without repeating text that was aimed at the AI.
    public static final String REVIEW_CONFLICT = 'Notes and CRM disagree: ';
    public static final String REVIEW_INSTRUCTION = 'Notes contained text addressed to the AI; flagged for review';

    /** The text, or if longer than max, cut after the last full sentence that fits (never mid-word). */
    public static String cutAtSentence(String text, Integer max) {
        if (text == null || text.length() <= max) {
            return text;
        }
        String head = text.left(max);
        Integer cut = Math.max(head.lastIndexOf('. '), Math.max(head.lastIndexOf('! '), head.lastIndexOf('? ')));
        if (cut > 0) {
            return head.left(cut + 1);
        }
        Integer space = head.lastIndexOf(' ');
        return (space > 0 ? head.left(space) : head) + '…';
    }

    // ------------------------------------------------------------------------------------------------ AI_Generation_Log__c

    static final Integer TEXT_LIMIT = 32768;

    /** One AI_Generation_Log__c row. Raw outputs are labelled by attempt; long text is capped at the field size. */
    public static AI_Generation_Log__c logRow(String recordId, String capability, String templateName, String templateVersion,
            String status, Integer attempts, List<String> notes, Long latencyMs, Integer contextChars, List<String> rawOutputs) {
        return new AI_Generation_Log__c(
            Record_Id__c = recordId,
            Capability__c = capability,
            Template_Name__c = templateName,
            Template_Version__c = templateVersion,
            Status__c = status,
            Attempts__c = attempts,
            Validation_Errors__c = cap(String.join(notes, '\n')),
            Latency_Ms__c = latencyMs,
            Context_Chars__c = contextChars,
            Raw_Output__c = cap(rawOutputText(rawOutputs)));
    }

    /** System mode on purpose: observability must not depend on the banker's permissions (bankers can't read the log). */
    public static void insertLogs(List<AI_Generation_Log__c> logs) {
        Database.insert(logs, false, AccessLevel.SYSTEM_MODE);
    }

    static String rawOutputText(List<String> rawOutputs) {
        List<String> parts = new List<String>();
        for (Integer i = 0; i < rawOutputs.size(); i++) {
            parts.add('--- Attempt ' + (i + 1) + ' ---\n' + rawOutputs[i]);
        }
        return String.join(parts, '\n');
    }

    @TestVisible
    static String cap(String s) {
        return String.isBlank(s) ? null : s.abbreviate(TEXT_LIMIT);
    }

    public static String firstError(Database.SaveResult r) {
        return r.getErrors().isEmpty() ? 'unknown error' : r.getErrors()[0].getMessage();
    }
}
