@IsTest
private class AiActionSupportTest {

    @IsTest
    static void gatewayErrorsAreClassified() {
        Map<String, String> expected = new Map<String, String>{
            'Insufficient Privileges: This feature is not currently enabled for this user.' => AiActionSupport.CATEGORY_PERMISSION,
            'You do not have access to this prompt template' => AiActionSupport.CATEGORY_PERMISSION,
            'Prompt template not found: Meeting_Prep_QA' => AiActionSupport.CATEGORY_CONFIGURATION,
            'The template has no active version' => AiActionSupport.CATEGORY_CONFIGURATION,
            'Read timed out' => AiActionSupport.CATEGORY_TRANSIENT,
            'Something new' => AiActionSupport.CATEGORY_TRANSIENT };
        for (String message : expected.keySet()) {
            Assert.areEqual(expected.get(message), AiActionSupport.classify(new MockLlmGateway.MockException(message)), message);
        }
        Assert.areEqual(AiActionSupport.CATEGORY_PERMISSION, AiActionSupport.classify(new NoAccessException()), 'By type');
    }

    @IsTest
    static void idsMustBeOfTheExpectedObject() {
        Account a = new Account(Name = 'Support Test');
        insert a;
        Assert.areEqual(a.Id, AiActionSupport.validId(a.Id, Account.SObjectType));
        Assert.areEqual(a.Id, AiActionSupport.validId(String.valueOf(a.Id).left(15), Account.SObjectType), '15-char Id normalised');
        Assert.isNull(AiActionSupport.validId(a.Id, Client_Meeting__c.SObjectType), 'Wrong object');
        Assert.isNull(AiActionSupport.validId('not-an-id', Account.SObjectType));
        Assert.isNull(AiActionSupport.validId(null, Account.SObjectType));
    }

    @IsTest
    static void linksAreAbsolutePlainLines() {
        Account a = new Account(Name = 'Support Test');
        insert a;
        String url = URL.getOrgDomainUrl().toExternalForm() + '/lightning/r/Account/' + a.Id + '/view';
        Assert.areEqual(url, AiActionSupport.recordUrl('Account', a.Id));
        Assert.areEqual('Open Support Test: ' + url, AiActionSupport.openLine('Support Test', 'Account', a.Id));
    }

    @IsTest
    static void textIsCutAtASentence() {
        Assert.isNull(AiActionSupport.cutAtSentence(null, 10));
        Assert.areEqual('Short.', AiActionSupport.cutAtSentence('Short.', 10));
        Assert.areEqual('One. Two.', AiActionSupport.cutAtSentence('One. Two. Three is long', 12));
        Assert.areEqual('one two…', AiActionSupport.cutAtSentence('one two three', 9));
        Assert.areEqual('abcdefgh…', AiActionSupport.cutAtSentence('abcdefghij', 8), 'No space: hard cut');
    }

    @IsTest
    static void logRowsAreBuiltCappedAndInsertedInSystemMode() {
        AI_Generation_Log__c row = AiActionSupport.logRow('001000000000001', 'Meeting Prep', 'Meeting_Prep_QA', '_2', 'Valid', 2,
            new List<String>{ 'Attempt 1: invalid', 'x'.repeat(40000) }, 1234, 4878, new List<String>{ '{"a":1}', '{"b":2}' });
        Assert.areEqual('Meeting Prep', row.Capability__c);
        Assert.areEqual('_2', row.Template_Version__c);
        Assert.areEqual(2, row.Attempts__c);
        Assert.areEqual(32768, row.Validation_Errors__c.length(), 'Capped at the field size');
        Assert.areEqual('--- Attempt 1 ---\n{"a":1}\n--- Attempt 2 ---\n{"b":2}', row.Raw_Output__c);
        Assert.isNull(AiActionSupport.cap('  '));

        AiActionSupport.insertLogs(new List<AI_Generation_Log__c>{ row });
        Assert.areEqual(1, [SELECT COUNT() FROM AI_Generation_Log__c WHERE Template_Name__c = 'Meeting_Prep_QA']);
    }

    @IsTest
    static void firstErrorReadsTheSaveResult() {
        Database.SaveResult failed = Database.insert(new Account(), false);   // Name is required
        Assert.isFalse(failed.isSuccess());
        Assert.isTrue(String.isNotBlank(AiActionSupport.firstError(failed)));
        Database.SaveResult ok = Database.insert(new Account(Name = 'Fine'), false);
        Assert.areEqual('unknown error', AiActionSupport.firstError(ok), 'No errors on success');
    }
}
