/**
 * Real gateway: runs a Prompt Builder template through ConnectApi.EinsteinLLM.
 *
 * - The template runs as the calling user, and its Apex grounding (ClientContextBuilder) runs inside the caller's transaction:
 *   about +5 SOQL and 0.5-0.7 s CPU per call (spike 2026-10-12, BUILD_LOG). ConnectApi generation is not a callout.
 * - It must run before any DML in the transaction; ClientSummaryService does all generations first.
 * - The response carries the resolved prompt but no template version (spike), so the version is logged from a constant.
 */
public with sharing class PromptTemplateGateway implements ILlmGateway {

    @TestVisible static final String INPUT_KEY = 'Input:Meeting';
    @TestVisible static final String APPLICATION_NAME = 'PromptBuilderPreview';

    public class GatewayException extends Exception {}

    public LlmResponse generate(String templateApiName, Id recordId) {
        // The only line tests can't run: tests never call the real LLM (CLAUDE.md).
        return toResponse(ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(templateApiName, buildInput(recordId)));
    }

    @TestVisible
    static ConnectApi.EinsteinPromptTemplateGenerationsInput buildInput(Id recordId) {
        if (recordId == null) {
            throw new GatewayException('A record id is required to run the template.');
        }
        ConnectApi.WrappedValue record = new ConnectApi.WrappedValue();
        record.value = new Map<String, String>{ 'id' => recordId };

        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{ INPUT_KEY => record };
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = APPLICATION_NAME;
        input.isPreview = false;
        return input;
    }

    @TestVisible
    static LlmResponse toResponse(ConnectApi.EinsteinPromptTemplateGenerationsRepresentation r) {
        if (r == null || r.generations == null || r.generations.isEmpty() || String.isBlank(r.generations[0].text)) {
            throw new GatewayException('The model returned no text.');
        }
        LlmResponse res = new LlmResponse();
        res.text = r.generations[0].text;
        res.resolvedPrompt = r.prompt;
        res.requestId = r.requestId;
        return res;
    }
}
