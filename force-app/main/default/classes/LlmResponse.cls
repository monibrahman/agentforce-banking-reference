/** What a gateway returns for one generation. */
public class LlmResponse {
    /** The model's output text (for Client_Meeting_Summary: the JSON summary). */
    public String text;
    /** The prompt after merge fields and grounding were resolved, i.e. exactly what the model saw. Null if not returned. */
    public String resolvedPrompt;
    /** Provider request id, for tracing a log row back to the generation. */
    public String requestId;
}
