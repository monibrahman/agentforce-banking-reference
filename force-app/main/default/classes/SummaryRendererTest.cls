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
                '<td>Project Atlas</td><td>Negotiation/Review</td><td>' + ClientContextBuilder.money(1200000000) + '</td>',
                '<td>send buyer list (TB)</td><td>Unassigned</td><td>not stated</td>',
                'Where the notes and CRM disagree', 'Data gaps', '<h3>Sources</h3>',
                '<small>[S3]</small> Meeting notes', '<small>[S5]</small> Opportunity: Project Atlas' }) {
            Assert.isTrue(html.contains(expected), 'Missing: ' + expected);
        }
        Assert.isFalse(html.contains(SummaryRenderer.REVIEW_HEADING), 'No review section without ignored text');
        Assert.isTrue(html.indexOf('[S3]</small> Meeting') < html.indexOf('[S5]</small> Opportunity'), 'Sources in id order');
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
