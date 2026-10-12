/**
 * Turns a validated summary (or, for the fallback, the context alone) into HTML for Summary__c and a PDF.
 * Every piece of model or banker text is HTML-escaped. No SOQL, no DML.
 */
public with sharing class SummaryRenderer {

    public static final String FALLBACK_BANNER = 'AI summary unavailable; data-only summary';
    public static final String REVIEW_HEADING = 'For review: text in the notes that looked like an instruction to the AI';
    static final Integer FIELD_LIMIT = 32768;
    static final String TRUNCATION_NOTE = '<p><i>Summary shortened to fit the record; the PDF has the full version.</i></p>';

    // ------------------------------------------------------------------------------------------------ AI summary

    /**
     * The validated summary as HTML. Source ids are shown as small labels; the Sources section at the end lists each id
     * actually cited, once, with the record it came from and a link to it (links are stripped for the PDF).
     */
    public static String toHtml(Map<String, Object> s, ClientContextBuilder.Context ctx) {
        List<String> h = new List<String>();
        Set<String> cited = new Set<String>();
        h.add('<h2>Client meeting summary: ' + esc(s.get('client')) + '</h2>');
        h.add('<p><b>Meeting date:</b> ' + esc(s.get('meetingDate')) + '<br/><b>Attendees:</b> '
            + esc(String.join(strings(s.get('attendees')), '; ')) + '</p>');

        h.add('<h3>Executive summary</h3><p>' + esc(s.get('executiveSummary')) + '</p>');

        h.add('<h3>Discussion points</h3>');
        h.add(bulletList(items(s, 'discussionPoints'), 'point', cited));

        h.add('<h3>Deals referenced</h3>');
        List<Map<String, Object>> deals = items(s, 'dealsReferenced');
        if (deals.isEmpty()) {
            h.add('<p>None.</p>');
        } else {
            h.add('<table border="1" cellpadding="4" cellspacing="0"><tr><th>Deal</th><th>Stage</th><th>Amount</th><th>Sources</th></tr>');
            for (Map<String, Object> d : deals) {
                Object amount = d.get('amount');
                h.add('<tr><td>' + esc(d.get('name')) + '</td><td>' + esc(d.get('stage')) + '</td><td>'
                    + (amount == null ? 'not given' : esc(ClientContextBuilder.money(Decimal.valueOf(String.valueOf(amount)))))
                    + '</td><td>' + sourceLabels(d, cited) + '</td></tr>');
            }
            h.add('</table>');
        }

        h.add('<h3>Risks and concerns</h3>');
        h.add(bulletList(items(s, 'risksAndConcerns'), 'risk', cited));

        h.add('<h3>Next steps</h3>');
        List<Map<String, Object>> steps = items(s, 'nextSteps');
        if (steps.isEmpty()) {
            h.add('<p>None.</p>');
        } else {
            h.add('<table border="1" cellpadding="4" cellspacing="0"><tr><th>Action (as written in the notes)</th><th>Owner</th><th>Due</th></tr>');
            for (Map<String, Object> st : steps) {
                sourceLabels(st, cited);
                h.add('<tr><td>' + esc(st.get('action')) + '</td><td>' + esc(st.get('owner')) + '</td><td>'
                    + (st.get('dueDate') == null ? 'not stated' : esc(st.get('dueDate'))) + '</td></tr>');
            }
            h.add('</table>');
        }

        List<Map<String, Object>> conflicts = items(s, 'conflicts');
        if (!conflicts.isEmpty()) {
            h.add('<h3>Where the notes and CRM disagree</h3>');
            h.add(bulletList(conflicts, 'description', cited));
        }
        List<String> gaps = strings(s.get('dataGaps'));
        if (!gaps.isEmpty()) {
            h.add('<h3>Data gaps</h3><ul>');
            for (String g : gaps) {
                h.add('<li>' + esc(g) + '</li>');
            }
            h.add('</ul>');
        }
        List<String> ignored = strings(s.get('ignoredInstructions'));
        if (!ignored.isEmpty()) {
            // Neutral wording on purpose: the patterns and the model can be wrong, so this is for review, not a verdict.
            h.add('<h3>' + esc(REVIEW_HEADING) + '</h3>');
            h.add('<p>The summary did not act on this text. Please check whether it was meant for the AI.</p><ul>');
            for (String q : ignored) {
                h.add('<li>"' + esc(q) + '"</li>');
            }
            h.add('</ul>');
        }

        if (!cited.isEmpty() && ctx != null) {
            h.add('<h3>Sources</h3><ul>');
            for (String id : sortedIds(cited)) {
                h.add('<li>' + sourceLine(id, ctx) + '</li>');
            }
            h.add('</ul>');
        }
        h.add('<p><small>Written by AI from CRM data and the meeting notes, then checked by code. Review before sharing.</small></p>');
        return String.join(h, '\n');
    }

    // ------------------------------------------------------------------------------------------------ fallback

    /** Data-only summary: the context the model would have seen, with no LLM text at all. */
    public static String fallbackHtml(ClientContextBuilder.Context ctx) {
        List<String> h = new List<String>{ '<h2>' + esc(FALLBACK_BANNER) + '</h2>',
            '<p>The AI summary could not be produced or did not pass the checks. Below are the facts on record for this meeting.</p>' };
        for (ClientContextBuilder.ContextSection sec : ctx.sections) {
            h.add('<h3>' + esc(sec.title) + '</h3>');
            if (sec.lines.isEmpty()) {
                h.add('<p>' + esc(sec.emptyNote == null ? 'Shortened to fit; see the record.' : sec.emptyNote) + '</p>');
            } else if (sec.title == 'OPEN OPPORTUNITIES') {
                h.add('<table border="1" cellpadding="4" cellspacing="0"><tr><th>Deal</th><th>Type</th><th>Stage</th><th>Amount</th><th>Close date</th></tr>');
                for (ClientContextBuilder.ContextLine l : sec.lines) {
                    List<String> cells = new List<String>();
                    for (String part : l.body.split(' \\| ')) {
                        cells.add('<td>' + esc(part.substringAfter(': ')) + '</td>');
                    }
                    h.add('<tr>' + String.join(cells, '') + '</tr>');
                }
                h.add('</table>');
            } else {
                h.add('<ul>');
                for (ClientContextBuilder.ContextLine l : sec.lines) {
                    h.add('<li>' + esc(l.body) + '</li>');
                }
                h.add('</ul>');
            }
            if (sec.title == 'CLIENT') {
                h.add('<h3>MEETING NOTES</h3>');
                h.add(ctx.notes == null ? '<p>No meeting notes recorded.</p>'
                    : '<p>' + esc(ctx.notes).replace('\n', '<br/>') + '</p>');
            }
        }
        return String.join(h, '\n');
    }

    // ------------------------------------------------------------------------------------------------ outputs

    /** HTML for the Summary__c rich text field, shortened at a tag boundary if over the field limit. */
    public static String forField(String bodyHtml) {
        if (bodyHtml.length() <= FIELD_LIMIT) {
            return bodyHtml;
        }
        String cut = bodyHtml.left(FIELD_LIMIT - TRUNCATION_NOTE.length() - 1);
        return cut.left(cut.lastIndexOf('>') + 1) + TRUNCATION_NOTE;
    }

    /** A printable PDF of the same body. Blob.toPdf supports Arial/Helvetica, so the CSS stays simple. */
    public static Blob toPdf(String bodyHtml) {
        return Blob.toPdf('<html><head><style>'
            + 'body { font-family: Arial, Helvetica, sans-serif; font-size: 10pt; }'
            + 'h2 { font-size: 14pt; } h3 { font-size: 11pt; margin-top: 14px; }'
            + 'table { border-collapse: collapse; width: 100%; } th { background: #eeeeee; text-align: left; }'
            + '</style></head><body>' + withoutLinks(bodyHtml) + '</body></html>');
    }

    /**
     * The PDF gets the source names as plain text: record links are relative Lightning URLs, which don't work once the
     * file leaves Salesforce. Only our own <a> tags exist in the body (all model and banker text is escaped).
     */
    @TestVisible
    static String withoutLinks(String bodyHtml) {
        return bodyHtml.replaceAll('<a [^>]*>', '').replace('</a>', '');
    }

    // ------------------------------------------------------------------------------------------------ helpers

    static String bulletList(List<Map<String, Object>> rows, String field, Set<String> cited) {
        if (rows.isEmpty()) {
            return '<p>None.</p>';
        }
        List<String> out = new List<String>{ '<ul>' };
        for (Map<String, Object> r : rows) {
            out.add('<li>' + esc(r.get(field)) + ' ' + sourceLabels(r, cited) + '</li>');
        }
        out.add('</ul>');
        return String.join(out, '');
    }

    static String sourceLabels(Map<String, Object> row, Set<String> cited) {
        List<String> ids = strings(row.get('sources'));
        cited.addAll(ids);
        return ids.isEmpty() ? '' : '<small>[' + esc(String.join(ids, ', ')) + ']</small>';
    }

    /**
     * One Sources line: 'S5 &mdash; Opportunity: Project Keel', linked to the record. The record type and Id come from
     * ctx.sources ('Opportunity:006...'); the name from the context line with that id. The notes link to their meeting.
     */
    static String sourceLine(String id, ClientContextBuilder.Context ctx) {
        String ref = ctx.sources.get(id);
        if (ref == null) {
            return esc(id) + ' &mdash; not in the context';
        }
        String kind = ref.substringBefore(':');
        String recordId = ref.substringAfterLast(':');
        String name = kind.equals(NOTES_KIND) ? nameOf('Client_Meeting__c:' + recordId, ctx) : nameOf(ref, ctx);
        String label = SOURCE_LABELS.containsKey(kind) ? SOURCE_LABELS.get(kind) : kind;
        return esc(id) + ' &mdash; <a href="/lightning/r/' + esc(recordId) + '/view">'
            + esc(name == null ? label : label + ': ' + name) + '</a>';
    }

    static final String NOTES_KIND = 'Client_Meeting__c.Meeting_Notes__c';
    static final Map<String, String> SOURCE_LABELS = new Map<String, String>{
        'Client_Meeting__c' => 'Meeting', NOTES_KIND => 'Meeting notes', 'Account' => 'Account',
        'Opportunity' => 'Opportunity', 'Contact' => 'Contact', 'Task' => 'Task', 'Event' => 'Event' };

    static String nameOf(String ref, ClientContextBuilder.Context ctx) {
        for (ClientContextBuilder.ContextSection sec : ctx.sections) {
            for (ClientContextBuilder.ContextLine l : sec.lines) {
                if (ref.equals(ctx.sources.get(l.id))) {
                    return l.name;
                }
            }
        }
        return null;
    }

    static List<String> sortedIds(Set<String> ids) {
        List<Integer> nums = new List<Integer>();
        for (String id : ids) {
            nums.add(Integer.valueOf(id.substring(1)));
        }
        nums.sort();
        List<String> out = new List<String>();
        for (Integer n : nums) {
            out.add('S' + n);
        }
        return out;
    }

    static List<Map<String, Object>> items(Map<String, Object> s, String key) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        Object v = s.get(key);
        if (v instanceof List<Object>) {
            for (Object o : (List<Object>) v) {
                out.add((Map<String, Object>) o);
            }
        }
        return out;
    }

    static List<String> strings(Object v) {
        List<String> out = new List<String>();
        if (v instanceof List<Object>) {
            for (Object o : (List<Object>) v) {
                out.add(String.valueOf(o));
            }
        }
        return out;
    }

    static String esc(Object v) {
        return v == null ? '' : String.valueOf(v).escapeHtml4();
    }
}
