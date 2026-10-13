/**
 * Finds the client (Account) a banker means ("Northwind"), so the Banker Assistant can get the account Id that
 * Answer Client Question needs. Same pattern as Find Client Meetings: USER_MODE (the banker only finds clients they can
 * see), up to 5 matches, Selected Client Id = "" unless exactly one client matches, links built in code as a plain
 * "Open <client>: https://..." line, and banker-facing messages (CLAUDE.md rule).
 *
 * Works for clients with no meetings, where Find Client Meetings can't help (D1, 2026-10-13).
 */
public with sharing class FindClientAction {

    public static final Integer MAX_RESULTS = 5;
    public static final Integer MAX_PER_CALL = 10;

    public static final String MESSAGE_NO_INPUT = 'No client name was given, so no search was run. Tell me the client name.';
    public static final String MESSAGE_NO_ACCESS = 'You don\'t have access to client records. Ask your Salesforce admin.';
    public static final String ASK_WHICH = 'Which one do you mean? Tell me the full client name.';

    public class Request {
        @InvocableVariable(label='Client Name'
            description='Part of the client\'s account name, any case, e.g. "northwind" finds "Northwind Maritime Group". Use the client name the banker gives. A deal or project name (e.g. "Keel") is not a client name: ask which client.')
        public String accountName;
    }

    public class ClientMatch {
        @AuraEnabled @InvocableVariable(label='Client Id' description='Record Id to pass to Answer Client Question. Never show it to the banker.')
        public String accountId;
        @AuraEnabled @InvocableVariable(label='Client Name' description='The client\'s account name.')
        public String name;
        @AuraEnabled @InvocableVariable(label='Industry' description='The client\'s industry, if recorded.')
        public String industry;
        @AuraEnabled @InvocableVariable(label='Record Link' description='Absolute link (https://...) to the client record.')
        public String recordUrl;
    }

    public class Response {
        @InvocableVariable(label='Success' description='False only when no client name was given or the banker has no access to client records; then show Message.')
        public Boolean success = false;
        @InvocableVariable(label='Total Matches' description='How many clients match in total, even when more than 5 do.')
        public Integer totalMatches = 0;
        @InvocableVariable(label='Clients' description='Up to 5 matching clients, by name.')
        public List<ClientMatch> clients = new List<ClientMatch>();
        @InvocableVariable(label='Matches Text'
            description='The matches, one line each: client name | industry | Id. For choosing the client and passing its Id on. When telling the banker, refer to clients by name; never show the Id.')
        public String matchesText;
        // Always "" (never null) unless exactly one client matches, so the agent script can test it with != "" and clear a
        // previously selected client on every search.
        @InvocableVariable(label='Selected Client Id'
            description='Use this as the Client Id for Answer Client Question. Set only when exactly one client matches; an empty string when there are none or several (then ask the banker which one). Never show it to the banker.')
        public String selectedAccountId = '';
        @InvocableVariable(label='Message'
            description='What was found, in plain language. When exactly one client matches it names the client and ends with a line "Open <client>: https://..." linking to the record. Show it to the banker exactly as returned, including that line: do not turn it into markdown and never write, rebuild or change the URL.')
        public String message;
    }

    @InvocableMethod(label='Find Client'
        description='Finds the client (account) the banker means, by name (partial, any case). Use it before Answer Client Question, for every question about a client. When exactly one client matches, Selected Client Id is set: use it as the Client Id. If several match, list them by name and ask which one. Show Message exactly as returned, including its link line. Never write, rebuild or change a URL yourself, and never show record Ids to the banker.')
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
        String name = req == null ? null : req.accountName?.trim();
        if (String.isBlank(name)) {
            res.message = MESSAGE_NO_INPUT;
            return;
        }
        String likeName = '%' + name.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%';
        List<Account> rows;
        try {
            res.totalMatches = [SELECT COUNT() FROM Account WHERE Name LIKE :likeName WITH USER_MODE];
            rows = [SELECT Id, Name, Industry FROM Account WHERE Name LIKE :likeName WITH USER_MODE ORDER BY Name LIMIT :MAX_RESULTS];
        } catch (QueryException e) {
            res.message = MESSAGE_NO_ACCESS;   // USER_MODE without access to Account
            return;
        } catch (SecurityException e) {
            res.message = MESSAGE_NO_ACCESS;   // inline WITH USER_MODE throws this one ("Access to entity 'Account' denied")
            return;
        }
        res.success = true;
        List<String> lines = new List<String>();
        for (Account a : rows) {
            ClientMatch m = new ClientMatch();
            m.accountId = a.Id;
            m.name = a.Name;
            m.industry = a.Industry;
            m.recordUrl = AiActionSupport.recordUrl('Account', a.Id);
            res.clients.add(m);
            lines.add(a.Name + ' | ' + (String.isBlank(a.Industry) ? 'industry not recorded' : a.Industry) + ' | Id: ' + a.Id);
        }
        res.matchesText = lines.isEmpty() ? null : String.join(lines, '\n');
        String criteria = 'client "' + name + '"';
        if (res.totalMatches == 0) {
            res.message = 'No clients match ' + criteria + '. Check the spelling, or tell me the full client name.';
        } else if (res.totalMatches == 1) {
            ClientMatch only = res.clients[0];
            res.selectedAccountId = only.accountId;
            res.message = 'Found 1 client matching ' + criteria + ': ' + only.name
                + (String.isBlank(only.industry) ? '' : ' (' + only.industry + ')') + '.\n'
                + AiActionSupport.openLine(only.name, 'Account', only.accountId);
        } else if (res.totalMatches > rows.size()) {
            res.message = 'Found ' + res.totalMatches + ' clients matching ' + criteria + '; showing the first ' + rows.size()
                + ' by name. ' + ASK_WHICH;
        } else {
            res.message = 'Found ' + res.totalMatches + ' clients matching ' + criteria + '. ' + ASK_WHICH;
        }
    }
}
