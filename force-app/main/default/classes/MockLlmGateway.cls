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
        calls++;
        dmlAtCall.add(Limits.getDmlStatements());
        if (queue.isEmpty()) {
            throw new MockException('MockLlmGateway: no more queued outputs (call ' + calls + ')');
        }
        Object next = queue.remove(0);
        if (next instanceof Exception) {
            throw (Exception) next;
        }
        LlmResponse res = new LlmResponse();
        res.text = (String) next;
        res.resolvedPrompt = resolvedPromptOverride != null ? resolvedPromptOverride
            : 'RULES...\n' + CONTEXT_BEGIN + ClientContextBuilder.build(recordId) + CONTEXT_END + '\nOUTPUT FORMAT...';
        res.requestId = 'mock-' + calls;
        return res;
    }
}
