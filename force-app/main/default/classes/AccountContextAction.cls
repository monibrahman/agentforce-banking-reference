/**
 * Prompt Builder grounding for the Meeting_Prep_QA template: the account-level client context
 * (ClientContextBuilder.buildAccountContext). A separate class because Apex allows one @InvocableMethod per class, and
 * ClientContextBuilder's is the meeting-level grounding for Client_Meeting_Summary.
 *
 * No capabilityType, like ClientContextBuilder: Flex templates insert any invocable as an Apex resource (BUILD_LOG).
 * Runs as the calling user inside the caller's transaction, so the USER_MODE queries apply the banker's access.
 */
public with sharing class AccountContextAction {

    public class Request {
        @InvocableVariable(label='Account' description='The client Account to build the question-answering context for.' required=true)
        public Account Account;
    }

    public class Response {
        @InvocableVariable(label='Prompt' description='Source-tagged account context ([S#] ids): client, open opportunities, recent meetings with notes, research notes, contacts and activity, within the character budget.')
        public String Prompt;
    }

    @InvocableMethod(label='Client Account Context' description='Returns source-tagged CRM context for a client account, for answering a banker\'s question about the client.')
    public static List<Response> getPrompt(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            if (req == null || req.Account == null) {
                throw new ClientContextBuilder.ContextException('Account is required.');
            }
            Response res = new Response();
            res.Prompt = ClientContextBuilder.buildAccountContext(req.Account.Id).text;
            responses.add(res);
        }
        return responses;
    }
}
