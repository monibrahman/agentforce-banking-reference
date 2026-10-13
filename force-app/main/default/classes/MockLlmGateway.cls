/**
 * Test double for ILlmGateway. Returns queued outputs in order: a String is the model's text, an Exception is thrown.
 * Like the real template, it resolves the prompt by running ClientContextBuilder for the record (same SOQL cost),
 * unless resolvedPromptOverride is set (used to simulate context drift).
 * Records the DML count at each call, so tests can prove no DML happened before a generation.
 */
@IsTest
public class MockLlmGateway implements ILlmGateway {

    public static final String CONTEXT_BEGIN = '=== CONTEXT (the only facts you may use) ===\n';
    public static final String CONTEXT_END = '\n=== END CONTEXT ===';

    public List<Object> queue = new List<Object>();
    public Integer calls = 0;
    public List<Integer> dmlAtCall = new List<Integer>();
    public String resolvedPromptOverride;

    public class MockException extends Exception {}

    public MockLlmGateway(List<Object> outputs) {
        queue.addAll(outputs);
    }

    public LlmResponse generate(String templateApiName, Id recordId) {
        String text = next();
        LlmResponse res = new LlmResponse();
        res.text = text;
        res.resolvedPrompt = resolvedPromptOverride != null ? resolvedPromptOverride
            : 'RULES...\n' + CONTEXT_BEGIN + ClientContextBuilder.build(recordId) + CONTEXT_END + '\nOUTPUT FORMAT...';
        res.requestId = 'mock-' + calls;
        return res;
    }

    // Meeting_Prep_QA: the resolved prompt frames the account context like the real template does.
    public static final String PREP_CONTEXT_BEGIN = 'CLIENT CONTEXT (every fact has a source id in brackets, e.g. [S3]):\n';
    public static final String PREP_CONTEXT_END = '\n\nRules:';
    public Map<String, Object> lastInputs;    // what the service passed, e.g. to prove the question is passed verbatim

    public LlmResponse generate(String templateApiName, Map<String, Object> inputs) {
        lastInputs = inputs;
        String text = next();
        LlmResponse res = new LlmResponse();
        res.text = text;
        res.resolvedPrompt = resolvedPromptOverride != null ? resolvedPromptOverride
            : 'QUESTION...\n' + PREP_CONTEXT_BEGIN + ClientContextBuilder.buildAccountContext((Id) inputs.get('Input:Account')).text
                + PREP_CONTEXT_END + '\n1. ...';
        res.requestId = 'mock-' + calls;
        return res;
    }

    String next() {
        calls++;
        dmlAtCall.add(Limits.getDmlStatements());
        if (queue.isEmpty()) {
            throw new MockException('MockLlmGateway: no more queued outputs (call ' + calls + ')');
        }
        Object n = queue.remove(0);
        if (n instanceof Exception) {
            throw (Exception) n;
        }
        return (String) n;
    }
}
