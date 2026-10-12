/**
 * The one seam between our code and the LLM. Production uses PromptTemplateGateway; tests use MockLlmGateway.
 * Tests never call the real model.
 */
public interface ILlmGateway {
    /** Runs the prompt template for one record and returns the model's text plus the resolved prompt it saw. */
    LlmResponse generate(String templateApiName, Id recordId);
}
