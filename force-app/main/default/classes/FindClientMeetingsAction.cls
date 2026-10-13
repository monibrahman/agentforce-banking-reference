/**
 * Finds Client Meeting records from what a banker says ("my Northwind meeting last week"), so the Banker Assistant can get
 * the meeting Id that Generate Client Meeting Summary needs.
 *
 * Design rule: code gathers the facts, the LLM only picks and writes. This action returns meeting metadata only (name,
 * client, date, attendees, summary status and time), never the notes or summary text, so the agent can't answer
 * "what was discussed" from raw notes; that is ClientSummaryService's validated job.
 *
 * Links are built here, absolute (org domain), never left to the LLM: in Preview the agent sometimes promised a link and
 * showed none, and once invented a link with another meeting's Id. With exactly one match the Message ends with a plain
 * "Open MTG-xxxx: https://..." line (outputs render as plain text, so markdown never became clickable) and Selected Meeting
 * Id is set.
 *
 * Security: queries run WITH USER_MODE, so the banker only finds meetings they can see. No object access returns a clear
 * message, never an exception.
 */
public with sharing class FindClientMeetingsAction {

    public static final Integer MAX_RESULTS = 5;
    public static final Integer MAX_PER_CALL = 10;

    public static final String MESSAGE_NO_INPUT = 'Provide a client name, an attendee name, a date range or a meeting name to search for.';
    public static final String MESSAGE_NO_ACCESS = 'You don\'t have access to client meetings. Ask your Salesforce admin.';

    public class Request {
        @InvocableVariable(label='Account Name'
            description='Part of the client\'s account name, any case, e.g. "northwind" finds "Northwind Maritime Group". Use the client name the banker gives. Leave empty if the banker gives only a date or a meeting name.')
        public String accountName;

        @InvocableVariable(label='Date From'
            description='Earliest meeting date to include, format YYYY-MM-DD, inclusive. For one day, pass the same date in Date From and Date To. For "last week", pass that week\'s Monday here and Sunday in Date To. Work out the dates from today\'s date; do not ask the banker to type a date format. Leave empty for no lower limit.')
        public Date dateFrom;

        @InvocableVariable(label='Date To'
            description='Latest meeting date to include, format YYYY-MM-DD, inclusive. For one day, the same date as Date From. Leave empty for no upper limit (e.g. "since 1 October" passes only Date From).')
        public Date dateTo;

        @InvocableVariable(label='Meeting Name'
            description='The meeting record name if the banker gives it, e.g. MTG-0019. Exact match, any case. Leave empty otherwise.')
        public String meetingName;

        @InvocableVariable(label='Attendee Name'
            description='Part of an attendee\'s name, any case, e.g. "Henrik". Use it when the banker names a person rather than a client ("What did Henrik say...?"). A deal or project name is not a client or an attendee: if the banker names only a deal, ask which client or meeting. Leave empty otherwise.')
        public String attendeeName;
    }

    /** One matching meeting. Metadata only: no notes, no summary text. */
    public class MeetingMatch {
        @AuraEnabled @InvocableVariable(label='Meeting Id' description='Record Id to pass to Generate Client Meeting Summary. Never show it to the banker.')
        public String meetingId;
        @AuraEnabled @InvocableVariable(label='Meeting Name' description='Meeting record name, e.g. MTG-0019. Use it with the client and date to refer to the meeting.')
        public String meetingName;
        @AuraEnabled @InvocableVariable(label='Account Name' description='The client the meeting was with.')
        public String accountName;
        @AuraEnabled @InvocableVariable(label='Meeting Date' description='Date of the meeting.')
        public Date meetingDate;
        @AuraEnabled @InvocableVariable(label='Attendees' description='Attendees as recorded on the meeting.')
        public String attendees;
        @AuraEnabled @InvocableVariable(label='Summary Status' description='Not Generated, Generated, Generated (Repaired), Fallback (data-only summary) or Failed.')
        public String summaryStatus;
        @AuraEnabled @InvocableVariable(label='Summary Generated At' description='When the current summary was generated; empty if there is none. If set, tell the banker a summary already exists and ask before generating a new one.')
        public Datetime summaryGeneratedAt;
        @AuraEnabled @InvocableVariable(label='Record Link' description='Absolute link (https://...) to the meeting record, where the summary and PDF are.')
        public String recordUrl;
    }

    public class Response {
        @InvocableVariable(label='Success' description='False only when no search input was given or the banker has no access to client meetings; then show Message.')
        public Boolean success = false;
        @InvocableVariable(label='Total Matches' description='How many meetings match in total, even when more than 5 do.')
        public Integer totalMatches = 0;
        @InvocableVariable(label='Meetings' description='Up to 5 matching meetings, newest first.')
        public List<MeetingMatch> meetings = new List<MeetingMatch>();
        @InvocableVariable(label='Matches Text'
            description='The matches, one line each: meeting name | client | date | attendees | summary status and time | Id. For choosing the meeting and passing its Id on. When telling the banker, refer to meetings by name, client and date; never show the Id.')
        public String matchesText;
        // Always "" (never null) unless exactly one meeting matches, so the agent script can test it with != "" and clear a
        // previously selected meeting on every search.
        @InvocableVariable(label='Selected Meeting Id'
            description='Use this as the Meeting Id for Generate Client Meeting Summary. Set only when exactly one meeting matches; an empty string when there are none or several (then ask the banker which one). Never show it to the banker.')
        public String selectedMeetingId = '';
        @InvocableVariable(label='Message'
            description='What was found, in plain language, including what to ask the banker when there is no match or too many. When exactly one meeting matches it names the meeting, client, date and summary status and ends with a line "Open MTG-xxxx: https://..." linking to the record. Show it to the banker exactly as returned, including that line: do not turn it into markdown and never write, rebuild or change the URL.')
        public String message;
    }

    @InvocableMethod(label='Find Client Meetings'
        description='Finds client meetings the banker can access by client account name (partial), attendee name (partial), a date range and/or the meeting name. Use it before Generate Client Meeting Summary. When exactly one meeting matches, Selected Meeting Id is set: use it as the Meeting Id. Returns up to 5 matches, newest first, and the total count. It returns no meeting notes or summaries: never use it to answer what was discussed. If more than one meeting matches and the request does not single one out, list them by name, client and date and ask which one. Show Message exactly as returned, including its link line. Never write, rebuild or change a URL yourself, and never show record Ids to the banker.')
    public static List<Response> find(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Integer i = 0; i < requests.size(); i++) {
            Response res = new Response();
            responses.add(res);
            if (i >= MAX_PER_CALL) {
                res.message = 'Too many searches in one request (max ' + MAX_PER_CALL + '); run again for the rest.';
                continue;
            }
            search(requests[i], res);
        }
        return responses;
    }

    static void search(Request req, Response res) {
        String accountName = req == null ? null : req.accountName?.trim();
        String meetingName = req == null ? null : req.meetingName?.trim();
        String attendeeName = req == null ? null : req.attendeeName?.trim();
        Date dateFrom = req?.dateFrom;
        Date dateTo = req?.dateTo;
        if (String.isBlank(accountName) && String.isBlank(meetingName) && String.isBlank(attendeeName)
                && dateFrom == null && dateTo == null) {
            res.message = MESSAGE_NO_INPUT;
            return;
        }

        List<String> filters = new List<String>();
        Map<String, Object> binds = new Map<String, Object>();
        if (String.isNotBlank(accountName)) {
            binds.put('accountLike', contains(accountName));
            filters.add('Account__r.Name LIKE :accountLike');
        }
        if (String.isNotBlank(attendeeName)) {
            binds.put('attendeeLike', contains(attendeeName));
            filters.add('Attendees__c LIKE :attendeeLike');
        }
        if (String.isNotBlank(meetingName)) {
            binds.put('meetingName', meetingName);
            filters.add('Name = :meetingName');
        }
        if (dateFrom != null) {
            binds.put('dateFrom', dateFrom);
            filters.add('Meeting_Date__c >= :dateFrom');
        }
        if (dateTo != null) {
            binds.put('dateTo', dateTo);
            filters.add('Meeting_Date__c <= :dateTo');
        }
        String whereClause = ' WHERE ' + String.join(filters, ' AND ');

        List<Client_Meeting__c> rows;
        try {
            res.totalMatches = Database.countQueryWithBinds('SELECT COUNT() FROM Client_Meeting__c' + whereClause, binds, AccessLevel.USER_MODE);
            // Metadata only. Never select Meeting_Notes__c, Summary__c or Summary_JSON__c here.
            rows = Database.queryWithBinds('SELECT Id, Name, Account__r.Name, Meeting_Date__c, Attendees__c, Summary_Status__c, '
                + 'Summary_Generated_At__c FROM Client_Meeting__c' + whereClause
                + ' ORDER BY Meeting_Date__c DESC NULLS LAST, Name DESC LIMIT ' + MAX_RESULTS, binds, AccessLevel.USER_MODE);
        } catch (QueryException e) {
            noAccess(res);   // USER_MODE without object or field access
            return;
        } catch (NoAccessException e) {
            noAccess(res);
            return;
        }

        res.success = true;
        List<String> lines = new List<String>();
        for (Client_Meeting__c m : rows) {
            MeetingMatch match = new MeetingMatch();
            match.meetingId = m.Id;
            match.meetingName = m.Name;
            match.accountName = m.Account__r?.Name;
            match.meetingDate = m.Meeting_Date__c;
            match.attendees = m.Attendees__c;
            match.summaryStatus = String.isBlank(m.Summary_Status__c) ? 'Not Generated' : m.Summary_Status__c;
            match.summaryGeneratedAt = m.Summary_Generated_At__c;
            match.recordUrl = ClientSummaryService.meetingUrl(m.Id);
            res.meetings.add(match);
            lines.add(describe(match));
        }
        res.matchesText = lines.isEmpty() ? null : String.join(lines, '\n');
        String criteria = searchedFor(accountName, attendeeName, meetingName, dateFrom, dateTo);
        if (res.totalMatches == 1) {
            // One match: hand the agent the Id directly, and build the link here; the LLM showed it only sometimes.
            MeetingMatch only = res.meetings[0];
            res.selectedMeetingId = only.meetingId;
            res.message = 'Found 1 meeting matching ' + criteria + ': ' + only.meetingName + ' with ' + only.accountName + ' on '
                + (only.meetingDate == null ? 'no date' : String.valueOf(only.meetingDate)) + '. Summary: ' + summaryLabel(only)
                + '.\n' + ClientSummaryService.openLine(only.meetingName, only.meetingId);
        } else {
            res.message = message(res.totalMatches, rows.size(), criteria);
        }
    }

    /** LIKE pattern for "contains", with wildcards escaped so "%" or "_" typed by the banker match literally. */
    static String contains(String value) {
        return '%' + value.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%';
    }

    static String summaryLabel(MeetingMatch m) {
        return m.summaryStatus + (m.summaryGeneratedAt == null ? '' : ', generated ' + m.summaryGeneratedAt.format('yyyy-MM-dd HH:mm z'));
    }

    static void noAccess(Response res) {
        res.totalMatches = 0;
        res.message = MESSAGE_NO_ACCESS;
    }

    static String describe(MeetingMatch m) {
        return m.meetingName + ' | ' + m.accountName + ' | ' + (m.meetingDate == null ? 'no date' : String.valueOf(m.meetingDate))
            + ' | Attendees: ' + (String.isBlank(m.attendees) ? 'not recorded' : m.attendees.normalizeSpace())
            + ' | Summary: ' + summaryLabel(m) + ' | Id: ' + m.meetingId;
    }

    static String message(Integer total, Integer shown, String criteria) {
        if (total == 0) {
            return 'No client meetings match ' + criteria + '. Check the spelling, or ask the banker for the client, the date or the meeting name.';
        }
        if (total > shown) {
            return 'Found ' + total + ' meetings matching ' + criteria + '; showing the ' + shown
                + ' most recent. Ask the banker for a date or the meeting name to narrow it down.';
        }
        return 'Found ' + total + ' meetings matching ' + criteria + '. Ask the banker which one, by name, client and date.';
    }

    static String searchedFor(String accountName, String attendeeName, String meetingName, Date dateFrom, Date dateTo) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(accountName)) {
            parts.add('client "' + accountName + '"');
        }
        if (String.isNotBlank(attendeeName)) {
            parts.add('attendee "' + attendeeName + '"');
        }
        if (String.isNotBlank(meetingName)) {
            parts.add('meeting "' + meetingName + '"');
        }
        if (dateFrom != null && dateTo != null) {
            parts.add(dateFrom == dateTo ? 'date ' + String.valueOf(dateFrom) : 'dates ' + String.valueOf(dateFrom) + ' to ' + String.valueOf(dateTo));
        } else if (dateFrom != null) {
            parts.add('dates from ' + String.valueOf(dateFrom));
        } else if (dateTo != null) {
            parts.add('dates up to ' + String.valueOf(dateTo));
        }
        return String.join(parts, ', ');
    }
}
