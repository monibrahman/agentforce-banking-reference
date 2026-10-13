/**
 * The one seam between our code and the LLM. Production uses PromptTemplateGateway; tests use MockLlmGateway.
 * Tests never call the real model.
 */
public interface ILlmGateway {
    /** Runs the prompt template for one record and returns the model's text plus the resolved prompt it saw. */
    LlmResponse generate(String templateApiName, Id recordId);

    /**
     * Runs a template with named inputs, e.g. Meeting_Prep_QA: 'Input:Account' => an Id (passed as a record),
     * 'Input:Question' => a String (passed as text).
     */
    LlmResponse generate(String templateApiName, Map<String, Object> inputs);
}
