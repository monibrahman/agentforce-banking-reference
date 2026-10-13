@IsTest
private class FindClientActionTest {

    @TestSetup
    static void setup() {
        SummaryTestData.createAll();   // 6 accounts named "... Test"
    }

    static FindClientAction.Response find(String name) {
        FindClientAction.Request req = new FindClientAction.Request();
        req.accountName = name;
        return FindClientAction.find(new List<FindClientAction.Request>{ req })[0];
    }

    @IsTest
    static void exactlyOneClientIsSelectedWithALinkLine() {
        FindClientAction.Response res = find('NORTHWIND');

        Account n = [SELECT Id FROM Account WHERE Name = :SummaryTestData.NORTHWIND];
        String expectedUrl = URL.getOrgDomainUrl().toExternalForm() + '/lightning/r/Account/' + n.Id + '/view';
        Assert.isTrue(res.success);
        Assert.areEqual(1, res.totalMatches);
        Assert.areEqual(n.Id, res.selectedAccountId);
        Assert.areEqual(SummaryTestData.NORTHWIND, res.clients[0].name);
        Assert.areEqual('Transportation', res.clients[0].industry);
        Assert.areEqual(expectedUrl, res.clients[0].recordUrl);
        Assert.areEqual('Northwind Test | Transportation | Id: ' + n.Id, res.matchesText);
        Assert.areEqual('Found 1 client matching client "NORTHWIND": Northwind Test (Transportation).\nOpen Northwind Test: ' + expectedUrl,
            res.message);
        Assert.isFalse(res.message.contains(']('), 'Plain text, no markdown');
    }

    @IsTest
    static void severalClientsAskWhichOne() {
        insert new Account(Name = 'Halverson Second Test');

        FindClientAction.Response two = find('halverson');
        Assert.areEqual(2, two.totalMatches);
        Assert.areEqual('', two.selectedAccountId, 'Several: nothing selected');
        Assert.areEqual('Found 2 clients matching client "halverson". ' + FindClientAction.ASK_WHICH, two.message);

        FindClientAction.Response many = find('test');
        Assert.areEqual(7, many.totalMatches);
        Assert.areEqual(5, many.clients.size(), 'At most 5 returned');
        Assert.areEqual('', many.selectedAccountId);
        Assert.isTrue(many.message.contains('showing the first 5 by name'), many.message);
    }

    @IsTest
    static void noMatchNoInputAndWildcards() {
        FindClientAction.Response none = find('Acme');
        Assert.isTrue(none.success);
        Assert.areEqual(0, none.totalMatches);
        Assert.isNull(none.matchesText);
        Assert.areEqual('', none.selectedAccountId);
        Assert.areEqual('No clients match client "Acme". Check the spelling, or tell me the full client name.', none.message);

        FindClientAction.Response blank = find('  ');
        Assert.isFalse(blank.success);
        Assert.areEqual(FindClientAction.MESSAGE_NO_INPUT, blank.message);
        Assert.areEqual('', FindClientAction.find(new List<FindClientAction.Request>{ null })[0].selectedAccountId);

        Assert.areEqual(0, find('%').totalMatches, '"%" must not match every client');
        Assert.areEqual(0, find('_').totalMatches);
    }

    @IsTest
    static void noAccessAndTooMany() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        User noAccess = new User(ProfileId = p.Id, LastName = 'NoAccess', Alias = 'noacc6',
            Username = 'noaccess6' + String.valueOf(Crypto.getRandomInteger()).replace('-', '') + '@example.com.test',
            Email = 'noaccess@example.com', TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        FindClientAction.Response res;
        System.runAs(noAccess) {
            res = find('Northwind');
        }
        Assert.isFalse(res.success);
        Assert.areEqual(FindClientAction.MESSAGE_NO_ACCESS, res.message);
        Assert.areEqual('', res.selectedAccountId);

        List<FindClientAction.Request> reqs = new List<FindClientAction.Request>();
        for (Integer i = 0; i <= FindClientAction.MAX_PER_CALL; i++) {
            FindClientAction.Request r = new FindClientAction.Request();
            r.accountName = 'Cobalt';
            reqs.add(r);
        }
        List<FindClientAction.Response> out = FindClientAction.find(reqs);
        Assert.areEqual(1, out[0].totalMatches);
        Assert.isTrue(out[FindClientAction.MAX_PER_CALL].message.startsWith('Too many searches'));
    }

    @IsTest
    static void messagesAreBankerFacing() {
        insert new Account(Name = 'Halverson Second Test');
        for (FindClientAction.Response r : new List<FindClientAction.Response>{ find('Northwind'), find('halverson'), find('test'),
                find('Acme'), find('') }) {
            SummaryTestData.assertBankerFacing(r.message, 'Find Client');
        }
        for (String c : new List<String>{ FindClientAction.MESSAGE_NO_INPUT, FindClientAction.MESSAGE_NO_ACCESS, FindClientAction.ASK_WHICH }) {
            SummaryTestData.assertBankerFacing(c, 'constant');
        }
    }
}
