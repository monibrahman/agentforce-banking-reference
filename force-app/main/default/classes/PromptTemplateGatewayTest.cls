/** Covers input building and response mapping. generate() itself is never called: tests never call the real LLM. */
@IsTest
private class PromptTemplateGatewayTest {

    @IsTest
    static void buildsTemplateInputForTheRecord() {
        Id recordId = '001000000000001AAA';

        ConnectApi.EinsteinPromptTemplateGenerationsInput input = PromptTemplateGateway.buildInput(recordId);

        Assert.areEqual(new Set<String>{ 'Input:Meeting' }, input.inputParams.keySet());
        Map<String, String> value = (Map<String, String>) input.inputParams.get('Input:Meeting').value;
        Assert.areEqual(recordId, value.get('id'));
        Assert.areEqual('PromptBuilderPreview', input.additionalConfig.applicationName);
        Assert.isFalse(input.isPreview, 'Must generate, not just resolve the prompt');
    }

    @IsTest
    static void buildsNamedInputsRecordsAsIdsAndTextAsText() {
        // Meeting_Prep_QA: Account is a record input, Question a primitive://String input.
        Id accountId = '001000000000001AAA';

        ConnectApi.EinsteinPromptTemplateGenerationsInput input = PromptTemplateGateway.buildInputs(
            new Map<String, Object>{ 'Input:Account' => accountId, 'Input:Question' => 'Any open deals?' });

        Assert.areEqual(new Set<String>{ 'Input:Account', 'Input:Question' }, input.inputParams.keySet());
        Assert.areEqual(accountId, ((Map<String, String>) input.inputParams.get('Input:Account').value).get('id'));
        Assert.areEqual('Any open deals?', (String) input.inputParams.get('Input:Question').value);
        Assert.areEqual('PromptBuilderPreview', input.additionalConfig.applicationName);
        Assert.isFalse(input.isPreview);
    }

    @IsTest
    static void rejectsMissingNamedInputs() {
        for (Map<String, Object> bad : new List<Map<String, Object>>{ null, new Map<String, Object>(),
                new Map<String, Object>{ 'Input:Question' => null } }) {
            try {
                PromptTemplateGateway.buildInputs(bad);
                Assert.fail('Expected GatewayException for ' + bad);
            } catch (PromptTemplateGateway.GatewayException e) {
                Assert.isTrue(e.getMessage().startsWith('Template input'), e.getMessage());
            }
        }
    }

    @IsTest
    static void rejectsMissingRecordId() {
        try {
            PromptTemplateGateway.buildInput(null);
            Assert.fail('Expected GatewayException');
        } catch (PromptTemplateGateway.GatewayException e) {
            Assert.isTrue(e.getMessage().contains('record id is required'));
        }
    }

    @IsTest
    static void mapsTextPromptAndRequestId() {
        ConnectApi.EinsteinLLMGenerationItemOutput g = new ConnectApi.EinsteinLLMGenerationItemOutput();
        g.text = '{"client":"X"}';
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation r = new ConnectApi.EinsteinPromptTemplateGenerationsRepresentation();
        r.generations = new List<ConnectApi.EinsteinLLMGenerationItemOutput>{ g };
        r.prompt = 'resolved prompt';
        r.requestId = 'req-1';

        LlmResponse res = PromptTemplateGateway.toResponse(r);

        Assert.areEqual('{"client":"X"}', res.text);
        Assert.areEqual('resolved prompt', res.resolvedPrompt);
        Assert.areEqual('req-1', res.requestId);
    }

    @IsTest
    static void emptyGenerationIsAnError() {
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation empty = new ConnectApi.EinsteinPromptTemplateGenerationsRepresentation();
        ConnectApi.EinsteinLLMGenerationItemOutput blank = new ConnectApi.EinsteinLLMGenerationItemOutput();
        blank.text = '  ';
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation blankText = new ConnectApi.EinsteinPromptTemplateGenerationsRepresentation();
        blankText.generations = new List<ConnectApi.EinsteinLLMGenerationItemOutput>{ blank };

        for (ConnectApi.EinsteinPromptTemplateGenerationsRepresentation r : new List<ConnectApi.EinsteinPromptTemplateGenerationsRepresentation>{
                null, empty, blankText }) {
            try {
                PromptTemplateGateway.toResponse(r);
                Assert.fail('Expected GatewayException');
            } catch (PromptTemplateGateway.GatewayException e) {
                Assert.areEqual('The model returned no text.', e.getMessage());
            }
        }
    }

    @IsTest
    static void mockReturnsQueuedOutputsThenThrows() {
        Account a = new Account(Name = 'Mock Client');
        insert a;
        Client_Meeting__c m = new Client_Meeting__c(Account__c = a.Id, Meeting_Notes__c = 'notes');
        insert m;
        MockLlmGateway mock = new MockLlmGateway(new List<Object>{ 'first', new MockLlmGateway.MockException('boom') });

        LlmResponse res = mock.generate('Client_Meeting_Summary', m.Id);
        Assert.areEqual('first', res.text);
        Assert.isTrue(res.resolvedPrompt.contains(MockLlmGateway.CONTEXT_BEGIN + ClientContextBuilder.build(m.Id) + MockLlmGateway.CONTEXT_END));
        for (Integer i = 0; i < 2; i++) {
            try {
                mock.generate('Client_Meeting_Summary', m.Id);
                Assert.fail('Expected an exception');
            } catch (MockLlmGateway.MockException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
        Assert.areEqual(3, mock.calls);
        Assert.areEqual(3, mock.dmlAtCall.size());
    }
}
