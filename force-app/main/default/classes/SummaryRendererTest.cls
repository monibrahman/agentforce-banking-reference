@IsTest
private class SummaryRendererTest {

    @TestSetup
    static void setup() {
        SummaryTestData.createAll();
    }

    @IsTest
    static void rendersEverySectionWithSources() {
        ClientContextBuilder.Context ctx = SummaryTestData.ctx(SummaryTestData.HALVERSON);
        Map<String, Object> s = SummaryTestData.halversonSummary();
        s.put('conflicts', new List<Object>{ new Map<String, Object>{
            'description' => 'Notes and CRM give different sizes.', 'sources' => new List<Object>{ 'S3', 'S5' } } });

        String html = SummaryRenderer.toHtml(s, ctx);

        for (String expected : new List<String>{ '<h2>Client meeting summary: Halverson Test</h2>', 'Executive summary',
                '<h3>Open deals for this client (from CRM)</h3>',
                '<td>Project Atlas</td><td>Negotiation/Review</td><td>' + ClientContextBuilder.money(1200000000) + '</td>',
                '<td>send buyer list (TB)</td><td>Unassigned</td><td>not stated</td>',
                'Where the notes and CRM disagree', 'Data gaps', '<h3>Sources</h3>' }) {
            Assert.isTrue(html.contains(expected), 'Missing: ' + expected);
        }
        Assert.isFalse(html.contains(SummaryRenderer.REVIEW_HEADING), 'No review section without ignored text');
    }

    @IsTest
    static void sourcesListEachCitedIdOnceWithARecordLink() {
        ClientContextBuilder.Context ctx = SummaryTestData.ctx(SummaryTestData.HALVERSON);
        Map<String, Object> s = SummaryTestData.halversonSummary();
        s.put('conflicts', new List<Object>{ new Map<String, Object>{
            'description' => 'Notes and CRM give different sizes.', 'sources' => new List<Object>{ 'S3', 'S5' } } });
        Id meetingId = SummaryTestData.meetingId(SummaryTestData.HALVERSON);
        Id atlasId = [SELECT Id FROM Opportunity WHERE Name = 'Project Atlas'].Id;
        Assert.areEqual('Opportunity:' + atlasId, ctx.sources.get('S5'), 'Fixture: S5 is Project Atlas');

        String html = SummaryRenderer.toHtml(s, ctx);
        String sources = html.substringAfter('<h3>Sources</h3>');

        String notesLine = '<li>S3 &mdash; <a href="/lightning/r/' + meetingId + '/view">Meeting notes: '
            + ctx.sections[0].lines[0].name + '</a></li>';
        String atlasLine = '<li>S5 &mdash; <a href="/lightning/r/' + atlasId + '/view">Opportunity: Project Atlas</a></li>';
        Assert.isTrue(sources.contains(notesLine), sources);
        Assert.isTrue(sources.contains(atlasLine), sources);
        Assert.areEqual(1, sources.countMatches('<li>S5 '), 'S5 is cited several times but listed once');
        Assert.isTrue(sources.indexOf('<li>S3 ') < sources.indexOf('<li>S5 '), 'Sources in id order');
        Assert.isTrue(sources.contains('<li>S4 &mdash; <a href="/lightning/r/'), 'S4 (cited in the deals table) is listed');
        Assert.isFalse(sources.contains('<li>S1 ') || sources.contains('<li>S2 '), 'Ids in the context but not cited are not listed');

        String pdfBody = SummaryRenderer.withoutLinks(html);
        Assert.isFalse(pdfBody.contains('<a '), 'No links in the PDF');
        Assert.isFalse(pdfBody.contains('</a>'));
        Assert.isTrue(pdfBody.contains('<li>S5 &mdash; Opportunity: Project Atlas</li>'), 'Plain text in the PDF');
    }

    @IsTest
    static void sourceNotInTheContextIsSaidPlainly() {
        ClientContextBuilder.Context ctx = SummaryTestData.ctx(SummaryTestData.HALVERSON);
        Map<String, Object> s = SummaryTestData.halversonSummary();
        s.put('dataGaps', new List<Object>());
        s.put('conflicts', new List<Object>{ new Map<String, Object>{
            'description' => 'x', 'sources' => new List<Object>{ 'S3', 'S99' } } });

        String html = SummaryRenderer.toHtml(s, ctx);

        Assert.isTrue(html.contains('<li>S99 &mdash; not in the context</li>'), html);
    }

    @IsTest
    static void escapesModelTextAndShowsIgnoredTextForReview() {
        Map<String, Object> s = SummaryTestData.northwindSummary();
        s.put('executiveSummary', 'Client meeting <script>alert(1)</script> & co.');

        String html = SummaryRenderer.toHtml(s, SummaryTestData.ctx(SummaryTestData.NORTHWIND));

        Assert.isFalse(html.contains('<script>'), 'Model text must be escaped');
        Assert.isTrue(html.contains('&lt;script&gt;alert(1)&lt;/script&gt; &amp; co.'));
        Assert.isTrue(html.contains(SummaryRenderer.REVIEW_HEADING));
        Assert.isTrue(html.contains('"' + SummaryTestData.INJECTION.escapeHtml4() + '"'));
        Assert.isTrue(html.contains('Please check whether it was meant for the AI'), 'For review, not a verdict');
    }

    @IsTest
    static void emptySectionsSayNone() {
        Map<String, Object> s = SummaryTestData.cobaltSummary();
        ((Map<String, Object>) s).put('dealsReferenced', new List<Object>{
            new Map<String, Object>{ 'name' => 'X', 'stage' => 'Y', 'amount' => null, 'sources' => new List<Object>() } });

        String html = SummaryRenderer.toHtml(s, null);

        Assert.isTrue(html.contains('<h3>Discussion points</h3>\n<p>None.</p>'));
        Assert.isTrue(html.contains('<h3>Next steps</h3>\n<p>None.</p>'));
        Assert.isTrue(html.contains('<td>not given</td>'));
        Assert.isFalse(html.contains('<h3>Sources</h3>'), 'No sources list without a context');
    }

    @IsTest
    static void fallbackShowsOnlyContextData() {
        ClientContextBuilder.Context ctx = SummaryTestData.ctx(SummaryTestData.NORTHWIND);

        String html = SummaryRenderer.fallbackHtml(ctx);

        Assert.isTrue(html.startsWith('<h2>' + SummaryRenderer.FALLBACK_BANNER + '</h2>'));
        Assert.isTrue(html.contains('<td>Project Keel</td><td>M&amp;A</td><td>Id. Decision Makers</td><td>'
            + ClientContextBuilder.money(850000000) + '</td>'), html);
        Assert.isTrue(html.contains('<h3>MEETING NOTES</h3>'));
        Assert.isTrue(html.contains('JW thinks one branch sells at ~850mm.<br/>'), 'Notes shown verbatim with line breaks');
        Assert.isTrue(html.contains('Contact: James Whitlock'));
    }

    @IsTest
    static void fallbackWithNoNotesAndNoDeals() {
        String html = SummaryRenderer.fallbackHtml(SummaryTestData.ctx(SummaryTestData.COBALT));

        Assert.isTrue(html.contains('<p>No meeting notes recorded.</p>'));
        Assert.isTrue(html.contains('<p>No open opportunities on record.</p>'));
    }

    @IsTest
    static void fieldHtmlIsCappedAtATagBoundary() {
        String small = '<p>short</p>';
        Assert.areEqual(small, SummaryRenderer.forField(small));

        String big = '<p>' + 'x'.repeat(40000) + '</p><ul><li>a</li></ul>';
        String capped = SummaryRenderer.forField('<h2>t</h2>' + big);
        Assert.isTrue(capped.length() <= 32768);
        Assert.isTrue(capped.endsWith('the PDF has the full version.</i></p>'));
        Assert.isTrue(capped.startsWith('<h2>t</h2>'));
    }

    @IsTest
    static void pdfIsProduced() {
        Blob pdf = SummaryRenderer.toPdf(SummaryRenderer.toHtml(SummaryTestData.halversonSummary(),
            SummaryTestData.ctx(SummaryTestData.HALVERSON)));
        Assert.isTrue(pdf.size() > 0);
    }
}
