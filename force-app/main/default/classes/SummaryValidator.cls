/**
 * Checks and repairs the model's JSON for Client_Meeting_Summary against the context the model saw.
 * Rules: CLAUDE.md > ClientSummaryService > Validator rules; evidence for each: docs/PROMPT_ITERATIONS.md.
 *
 * Outcomes:
 * - VALID       the output passes every check unchanged.
 * - REPAIRABLE  code fixed it deterministically (fence stripped, placeholders removed, next step rebuilt from the full clause
 *               in the notes, owner decided in code, a missed injection added to ignoredInstructions, a notes-vs-CRM amount
 *               conflict the model left out added to conflicts). summary/json hold the fix.
 * - INVALID     anything code can't safely fix; errors explain why. The caller retries once, then falls back to data only.
 *
 * Owners: "X to verb" yields X only when X is an attendee/contact (full name or unique initials) or a team word from
 * TEAM_WORDS; "we"/"our team" -> "Deal team"; a trailing "(XX)" or anything else -> "Unassigned". So "write to the CFO" is
 * Unassigned, not "write".
 *
 * Next-step clauses: comma, semicolon, newline and a sentence-ending period bound a clause (a period after an initial, a
 * known abbreviation or between digits does not); a colon or spaced dash starts one. An objectless "<owner> to <verb>"
 * ("PR to set up") takes the clause before it across one comma. Found by holdout MTG-0014 (PROMPT_ITERATIONS).
 *
 * Known limits (stated in PROMPT_ITERATIONS / FUNCTIONAL_SPEC_NOTES): a cited source can exist without supporting the claim;
 * wording and attribution are only checked offline.
 *
 * Pure Apex: no SOQL, no DML.
 */
public with sharing class SummaryValidator {

    public enum Outcome { VALID, REPAIRABLE, INVALID }

    public class Result {
        public Outcome outcome;
        public Map<String, Object> summary;    // the final summary (repaired if needed); null when INVALID
        public String json;                    // JSON.serialize(summary); null when INVALID
        public List<String> repairs = new List<String>();
        public List<String> errors = new List<String>();
    }

    static final Set<String> TOP_KEYS = new Set<String>{ 'client', 'meetingDate', 'executiveSummary', 'attendees',
        'discussionPoints', 'dealsReferenced', 'risksAndConcerns', 'nextSteps', 'dataGaps', 'ignoredInstructions', 'conflicts' };

    // Field types of the objects inside each array (docs/summary_schema.json). Every listed field is required.
    static final Map<String, Map<String, String>> ITEM_FIELDS = new Map<String, Map<String, String>>{
        'discussionPoints' => new Map<String, String>{ 'point' => 'string', 'sources' => 'sources' },
        'dealsReferenced' => new Map<String, String>{ 'name' => 'string', 'stage' => 'string', 'amount' => 'amount', 'sources' => 'sources' },
        'risksAndConcerns' => new Map<String, String>{ 'risk' => 'string', 'sources' => 'sources' },
        'nextSteps' => new Map<String, String>{ 'action' => 'string', 'owner' => 'string', 'dueDate' => 'date', 'sources' => 'sources' },
        'conflicts' => new Map<String, String>{ 'description' => 'string', 'sources' => 'sources2' }
    };
    static final List<String> STRING_ARRAYS = new List<String>{ 'attendees', 'dataGaps', 'ignoredInstructions' };
    static final Map<String, String> FREE_TEXT_ITEMS = new Map<String, String>{
        'discussionPoints' => 'point', 'risksAndConcerns' => 'risk', 'conflicts' => 'description' };

    static final Integer MAX_SUMMARY_CHARS = 800;
    static final Pattern SOURCE_ID = Pattern.compile('^S[0-9]+$');
    static final Pattern ID_IN_TEXT = Pattern.compile('(?i)\\[?\\bS[0-9]+\\b\\]?|\\bsources?\\s*:');
    static final Pattern ISO_DATE = Pattern.compile('^\\d{4}-\\d{2}-\\d{2}$');
    static final Pattern PLACEHOLDER = Pattern.compile('(?i)^\\s*(none|n/?a|nil|null|-+)?\\s*\\.?\\s*$');
    static final Pattern TRAILING_BRACKET = Pattern.compile('\\(\\s*[A-Za-z]{1,4}\\s*\\)\\s*$');
    static final Pattern WE_OWNER = Pattern.compile('(?i)^(we|our team|our [a-z&+ ]{1,20} team)\\b');
    static final Pattern INITIALS = Pattern.compile('^[A-Z]{2,3}$');
    /** Teams that can own a next step ("legal to check ..."). Anything else before " to " must be a known person. */
    @TestVisible
    static final List<String> TEAM_WORDS = new List<String>{ 'legal', 'tax', 'compliance', 'credit', 'ECM', 'DCM', 'M&A' };
    /** A period after one of these is not a sentence end ("approx. 850mm"). Compared lower case, with the period. */
    @TestVisible
    static final Set<String> ABBREVIATIONS = new Set<String>{ 'approx.', 'e.g.', 'i.e.', 'vs.', 'mr.', 'mrs.', 'ms.', 'dr.',
        'inc.', 'corp.', 'co.', 'no.', 'wk.' };
    /** "<owner> to <verb>" with no object: up to 2 words for the owner, up to 2 after "to" ("PR to set up"). */
    static final Pattern OBJECTLESS = Pattern.compile('^\\S+(\\s\\S+)? to [a-z]\\S*(\\s\\S+)?$');

    // Money in free text: $, USD, ~, commas, decimals, k/m/mm/bn/million/billion. A match counts as money if it has a
    // currency marker or an unambiguous size word (bn, billion, mm, million, b). '3x', '11 NDAs', '9:30', dates don't match.
    static final Pattern MONEY = Pattern.compile(
        '(?i)(USD|US\\$|\\$)?\\s?~?\\s?(\\d{1,3}(?:,\\d{3})+(?:\\.\\d+)?|\\d+(?:\\.\\d+)?)\\s?(billion|million|thousand|bn|mm|m|k|b)?(?![A-Za-z0-9])');

    /**
     * Text addressed to an AI rather than a banker's note. One list, used three ways: next-step clauses that match are
     * rejected, amounts inside matching sentences are not allowed, and matching sentences the model didn't quote are added
     * to ignoredInstructions. Documented in PROMPT_ITERATIONS.md.
     */
    @TestVisible
    static final List<Pattern> INJECTION_PATTERNS = new List<Pattern>{
        Pattern.compile('(?i)\\b(ignore|disregard|forget|override)\\b[^.\\n]{0,40}\\b(instructions?|prompts?|rules|guidelines)\\b'),
        Pattern.compile('(?i)\\b(ignore|disregard|forget)\\b[^.\\n]{0,20}\\b(previous|prior|above)\\b'),
        Pattern.compile('(?i)\\byou are now\\b'),
        Pattern.compile('(?i)\\b(system prompt|system message|developer message)\\b'),
        Pattern.compile('(?i)^\\s*(system|assistant)\\s*:'),
        Pattern.compile('(?i)\\b(pretend to be|role-?play as)\\b'),   // not "act as": "act as sole bookrunner" is banking
        Pattern.compile('(?i)\\binvent\\b[^.\\n]{0,30}\\b(deal|amount|figure|number|numbers|revenue|client)\\b')
    };

    // ------------------------------------------------------------------------------------------------ entry point

    public static Result validate(String raw, ClientContextBuilder.Context ctx) {
        Result res = new Result();
        Map<String, Object> s = parse(raw, res);
        if (s != null) {
            checkSchema(s, res.errors);
        }
        if (res.errors.isEmpty()) {
            checkSourceIds(s, ctx, res.errors);
            checkAmounts(s, ctx, res.errors);
            removePlaceholders(s, res.repairs);
            checkIgnoredInstructions(s, ctx, res);
            checkNextSteps(s, ctx, res);
        }
        if (res.errors.isEmpty()) {
            addAmountConflicts(s, ctx, res);
        }
        if (!res.errors.isEmpty()) {
            res.outcome = Outcome.INVALID;
            return res;
        }
        res.outcome = res.repairs.isEmpty() ? Outcome.VALID : Outcome.REPAIRABLE;
        res.summary = s;
        res.json = JSON.serialize(s);
        return res;
    }

    // ------------------------------------------------------------------------------------------------ 1. parse

    static Map<String, Object> parse(String raw, Result res) {
        if (String.isBlank(raw)) {
            res.errors.add('Empty output.');
            return null;
        }
        String text = raw.trim();
        if (text.startsWith('```')) {
            text = text.removeStart('```json').removeStart('```JSON').removeStart('```').removeEnd('```').trim();
            res.repairs.add('Removed a markdown code fence around the JSON.');
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(text);
        } catch (JSONException e) {
            res.errors.add('Invalid JSON: ' + e.getMessage());
            return null;
        }
        if (!(parsed instanceof Map<String, Object>)) {
            res.errors.add('Output is not a JSON object.');
            return null;
        }
        return (Map<String, Object>) parsed;
    }

    // ------------------------------------------------------------------------------------------------ 2. schema

    static void checkSchema(Map<String, Object> s, List<String> errors) {
        for (String k : TOP_KEYS) {
            if (!s.containsKey(k)) {
                errors.add('Missing required key: ' + k);
            }
        }
        for (String k : s.keySet()) {
            if (!TOP_KEYS.contains(k)) {
                errors.add('Unknown key: ' + k);
            }
        }
        for (String k : new List<String>{ 'client', 'meetingDate', 'executiveSummary' }) {
            if (s.containsKey(k) && !(s.get(k) instanceof String)) {
                errors.add(k + ' must be a string.');
            }
        }
        if (s.get('executiveSummary') instanceof String && ((String) s.get('executiveSummary')).length() > MAX_SUMMARY_CHARS) {
            errors.add('executiveSummary is longer than ' + MAX_SUMMARY_CHARS + ' characters.');
        }
        for (String k : STRING_ARRAYS) {
            if (!s.containsKey(k)) {
                continue;
            }
            if (!(s.get(k) instanceof List<Object>)) {
                errors.add(k + ' must be an array.');
                continue;
            }
            for (Object o : (List<Object>) s.get(k)) {
                if (!(o instanceof String)) {
                    errors.add(k + ' must contain only strings.');
                    break;
                }
            }
        }
        for (String arrayKey : ITEM_FIELDS.keySet()) {
            if (!s.containsKey(arrayKey)) {
                continue;
            }
            if (!(s.get(arrayKey) instanceof List<Object>)) {
                errors.add(arrayKey + ' must be an array.');
                continue;
            }
            List<Object> items = (List<Object>) s.get(arrayKey);
            for (Integer i = 0; i < items.size(); i++) {
                checkItem(arrayKey + '[' + i + ']', items[i], ITEM_FIELDS.get(arrayKey), errors);
            }
        }
    }

    static void checkItem(String path, Object item, Map<String, String> fields, List<String> errors) {
        if (!(item instanceof Map<String, Object>)) {
            errors.add(path + ' must be an object.');
            return;
        }
        Map<String, Object> m = (Map<String, Object>) item;
        for (String k : m.keySet()) {
            if (!fields.containsKey(k)) {
                errors.add(path + ': unknown key ' + k);
            }
        }
        for (String k : fields.keySet()) {
            String p = path + '.' + k;
            if (!m.containsKey(k)) {
                errors.add(p + ' is required.');
                continue;
            }
            Object v = m.get(k);
            String type = fields.get(k);
            if (type == 'string' && !(v instanceof String)) {
                errors.add(p + ' must be a string.');
            } else if (type == 'amount' && v != null && !(v instanceof Decimal || v instanceof Integer || v instanceof Long)) {
                errors.add(p + ' must be a number or null.');
            } else if (type == 'date' && v != null && !(v instanceof String && ISO_DATE.matcher((String) v).matches())) {
                errors.add(p + ' must be YYYY-MM-DD or null.');
            } else if (type.startsWith('sources')) {
                checkSources(p, v, type == 'sources2' ? 2 : 1, errors);
            }
        }
    }

    static void checkSources(String path, Object v, Integer minDistinct, List<String> errors) {
        if (!(v instanceof List<Object>)) {
            errors.add(path + ' must be an array.');
            return;
        }
        Set<String> distinct = new Set<String>();
        for (Object o : (List<Object>) v) {
            if (!(o instanceof String) || !SOURCE_ID.matcher((String) o).matches()) {
                errors.add(path + ': "' + o + '" is not a source id like S1.');
                return;
            }
            distinct.add((String) o);
        }
        if (minDistinct > 1 && distinct.size() < ((List<Object>) v).size()) {
            errors.add(path + ' repeats a source id.');
        } else if (distinct.size() < minDistinct) {
            errors.add(path + ' needs at least ' + minDistinct + (minDistinct > 1 ? ' different source ids.' : ' source id.'));
        }
    }

    // ------------------------------------------------------------------------------------------------ 3. source ids

    static void checkSourceIds(Map<String, Object> s, ClientContextBuilder.Context ctx, List<String> errors) {
        for (String arrayKey : ITEM_FIELDS.keySet()) {
            List<Object> items = (List<Object>) s.get(arrayKey);
            for (Integer i = 0; i < items.size(); i++) {
                for (Object id : (List<Object>) ((Map<String, Object>) items[i]).get('sources')) {
                    if (!ctx.sources.containsKey((String) id)) {
                        errors.add(arrayKey + '[' + i + ']: source ' + id + ' is not in the context.');
                    }
                }
            }
        }
        for (FreeText t : freeText(s)) {
            if (ID_IN_TEXT.matcher(t.text).find()) {
                errors.add(t.path + ': source ids belong in sources arrays, not in text.');
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ 4. amounts

    static void checkAmounts(Map<String, Object> s, ClientContextBuilder.Context ctx, List<String> errors) {
        Set<Long> allowed = new Set<Long>();
        for (Decimal d : ctx.amounts) {
            allowed.add(d.setScale(0, RoundingMode.HALF_UP).longValue());
        }
        // Anything the model saw, except amounts inside injection sentences ("invent a $5B deal" must never pass).
        allowed.addAll(parseMoney(withoutInjection(ctx.text)));

        List<Object> deals = (List<Object>) s.get('dealsReferenced');
        for (Integer i = 0; i < deals.size(); i++) {
            Object a = ((Map<String, Object>) deals[i]).get('amount');
            if (a != null) {
                Long v = Decimal.valueOf(String.valueOf(a)).setScale(0, RoundingMode.HALF_UP).longValue();
                if (!allowed.contains(v)) {
                    errors.add('dealsReferenced[' + i + '].amount ' + a + ' is not in the context.');
                }
            }
        }
        for (FreeText t : freeText(s)) {
            for (Long v : parseMoney(t.text)) {
                if (!allowed.contains(v)) {
                    errors.add(t.path + ': amount ' + v + ' is not in the context.');
                }
            }
        }
    }

    /** Every money expression in the text, as a whole number. */
    @TestVisible
    static List<Long> parseMoney(String text) {
        List<Long> out = new List<Long>();
        for (Money m : moneyIn(text)) {
            out.add(m.value);
        }
        return out;
    }

    /** A money expression as written ("~$1.1bn") and its value. */
    private class Money {
        String written;
        Long value;
        Money(String written, Long value) {
            this.written = written;
            this.value = value;
        }
    }

    static List<Money> moneyIn(String text) {
        List<Money> out = new List<Money>();
        if (String.isBlank(text)) {
            return out;
        }
        Matcher m = MONEY.matcher(text);
        while (m.find()) {
            String currencyMark = m.group(1);   // 'currency' is a reserved word in Apex
            String suffix = m.group(3) == null ? '' : m.group(3).toLowerCase();
            Boolean sizeWord = new Set<String>{ 'bn', 'billion', 'mm', 'million', 'b' }.contains(suffix);
            if (currencyMark == null && !sizeWord) {
                continue;
            }
            Decimal value = Decimal.valueOf(m.group(2).remove(','));
            if (suffix == 'k' || suffix == 'thousand') {
                value *= 1000;
            } else if (suffix == 'm' || suffix == 'mm' || suffix == 'million') {
                value *= 1000000;
            } else if (suffix == 'b' || suffix == 'bn' || suffix == 'billion') {
                value *= 1000000000;
            }
            String written = m.group(0).trim();
            if (m.start() > 0 && text.substring(m.start() - 1, m.start()) == '~') {
                written = '~' + written;          // "~$1.1bn": the regex takes "~" only before the currency mark
            }
            out.add(new Money(written, value.setScale(0, RoundingMode.HALF_UP).longValue()));
        }
        return out;
    }

    // ------------------------------------------------------------------------------------------------ 4b. amount conflicts

    /** Words in an opportunity name that don't identify the deal. The client's account name is excluded as well. */
    @TestVisible
    static final Set<String> GENERIC_DEAL_WORDS = new Set<String>{ 'project', 'acquisition', 'sale', 'offering', 'refinancing',
        'of', 'the' };
    static final Decimal CONFLICT_TOLERANCE = 0.10;

    /**
     * Deterministic notes-vs-CRM size check (the prompt leaves conflicts empty "when in doubt", which misses real ones; see
     * PROMPT_ITERATIONS "Amount conflicts"). For each notes sentence that names an open opportunity by a distinctive word
     * and states an amount: if no amount in the sentence is within 10% of that opportunity's CRM amount, a conflict is
     * added as a repair. Amounts that match another context figure (another deal, revenue) are not counted, injection
     * sentences are skipped, and nothing is added when the model already reported a conflict citing the notes and that
     * opportunity.
     */
    static void addAmountConflicts(Map<String, Object> s, ClientContextBuilder.Context ctx, Result res) {
        if (ctx.notes == null) {
            return;
        }
        List<ClientContextBuilder.ContextLine> opps = new List<ClientContextBuilder.ContextLine>();
        String accountName = '';
        for (ClientContextBuilder.ContextSection sec : ctx.sections) {
            for (ClientContextBuilder.ContextLine l : sec.lines) {
                if (sec.title == 'OPEN OPPORTUNITIES' && l.amount != null && l.amount != 0 && l.name != null) {
                    opps.add(l);
                } else if (sec.title == 'CLIENT' && l.name != null) {
                    accountName = l.name;
                }
            }
        }
        List<Object> conflicts = (List<Object>) s.get('conflicts');
        Set<String> flagged = new Set<String>();
        for (String sentence : noteSentences(ctx.notes)) {
            List<Money> amounts = moneyIn(sentence);
            if (amounts.isEmpty() || matchesInjection(sentence)) {
                continue;
            }
            for (ClientContextBuilder.ContextLine opp : opps) {
                if (flagged.contains(opp.id) || !namesDeal(sentence, opp.name, accountName)) {
                    continue;
                }
                Money differing = differingAmount(amounts, opp, ctx);
                if (differing == null || alreadyReported(conflicts, ctx.notesSourceId, opp.id)) {
                    continue;
                }
                flagged.add(opp.id);
                conflicts.add(new Map<String, Object>{
                    'description' => 'Notes state ' + differing.written + ' for ' + opp.name + '; CRM amount is '
                        + ClientContextBuilder.money(opp.amount) + '. CRM may be out of date — review the opportunity.',
                    'sources' => new List<Object>{ ctx.notesSourceId, opp.id } });
                res.repairs.add('Added a notes-vs-CRM amount conflict for ' + opp.name + ' (' + opp.id + '): notes '
                    + differing.written + ', CRM ' + ClientContextBuilder.money(opp.amount) + '.');
            }
        }
    }

    /** True when the sentence contains a distinctive word of the deal name, as a whole word, ignoring case. */
    @TestVisible
    static Boolean namesDeal(String sentence, String dealName, String accountName) {
        Set<String> skip = new Set<String>(GENERIC_DEAL_WORDS);
        for (String w : words(accountName)) {
            skip.add(w.toLowerCase());
        }
        for (String w : words(dealName)) {
            if (w.length() < 3 || skip.contains(w.toLowerCase())) {
                continue;
            }
            if (Pattern.compile('(?i)(?<![A-Za-z0-9])' + Pattern.quote(w) + '(?![A-Za-z0-9])').matcher(sentence).find()) {
                return true;
            }
        }
        return false;
    }

    /** Words of a name, hyphenated words kept whole ("Follow-on"), surrounding punctuation removed. */
    static List<String> words(String name) {
        List<String> out = new List<String>();
        for (String w : String.isBlank(name) ? new List<String>() : name.split('\\s+')) {
            w = w.replaceAll('^[^A-Za-z0-9&]+|[^A-Za-z0-9&]+$', '');
            if (w.length() > 0) {
                out.add(w);
            }
        }
        return out;
    }

    /**
     * The amount in the sentence that conflicts with the opportunity, or null. Null when any amount is within 10% of the
     * opportunity's CRM amount (the notes agree), or when every other amount matches another context figure (it is about
     * something else: another deal, the client's revenue).
     */
    static Money differingAmount(List<Money> amounts, ClientContextBuilder.ContextLine opp, ClientContextBuilder.Context ctx) {
        Money differing;
        for (Money m : amounts) {
            if (within(m.value, opp.amount)) {
                return null;
            }
            Boolean otherFigure = false;
            for (Decimal other : ctx.amounts) {
                otherFigure |= other != opp.amount && within(m.value, other);
            }
            if (!otherFigure && differing == null) {
                differing = m;
            }
        }
        return differing;
    }

    static Boolean within(Long value, Decimal reference) {
        return reference != 0 && Math.abs(value - reference) <= CONFLICT_TOLERANCE * Math.abs(reference);
    }

    static Boolean alreadyReported(List<Object> conflicts, String notesId, String oppId) {
        for (Object c : conflicts) {
            List<Object> ids = (List<Object>) ((Map<String, Object>) c).get('sources');
            if (ids.contains(notesId) && ids.contains(oppId)) {
                return true;
            }
        }
        return false;
    }

    /** Notes split on newlines and sentence ends; "approx. 850mm" and "S. Mendes" stay whole (isSentenceEnd). */
    @TestVisible
    static List<String> noteSentences(String notes) {
        List<String> out = new List<String>();
        Integer start = 0;
        for (Integer i = 0; i < notes.length(); i++) {
            String c = notes.substring(i, i + 1);
            Boolean sentenceEnds = c == '\n' || isSentenceEnd(notes, i)
                || ('?!'.contains(c) && (i + 1 == notes.length() || notes.substring(i + 1, i + 2).isWhitespace()));
            if (sentenceEnds) {
                if (String.isNotBlank(notes.substring(start, i + 1))) {
                    out.add(notes.substring(start, i + 1).trim());
                }
                start = i + 1;
            }
        }
        if (String.isNotBlank(notes.substring(start))) {
            out.add(notes.substring(start).trim());
        }
        return out;
    }

    // ------------------------------------------------------------------------------------------------ 5. ignoredInstructions

    static void checkIgnoredInstructions(Map<String, Object> s, ClientContextBuilder.Context ctx, Result res) {
        List<Object> quotes = (List<Object>) s.get('ignoredInstructions');
        String notes = ctx.notes == null ? '' : collapse(ctx.notes);
        for (Integer i = 0; i < quotes.size(); i++) {
            String q = (String) quotes[i];
            String path = 'ignoredInstructions[' + i + ']';
            if (!notes.contains(collapse(q))) {
                res.errors.add(path + ' is not text from the meeting notes.');
            } else if (!matchesInjection(q)) {
                // Size limits only for quotes that don't look like an injection: notes that are entirely an injection must pass.
                if (q.contains('\n')) {
                    res.errors.add(path + ' spans several lines of the notes and is not an instruction to the AI.');
                } else if (collapse(q).length() * 2 > notes.length()) {
                    res.errors.add(path + ' covers more than half of the notes and is not an instruction to the AI.');
                }
            }
        }
        // Code second opinion: injection sentences the model didn't quote are added for review.
        for (String sentence : injectionSentences(ctx.notes)) {
            Boolean quoted = false;
            for (Object q : quotes) {
                String cq = collapse((String) q);
                quoted |= cq.contains(collapse(sentence)) || collapse(sentence).contains(cq);
            }
            if (!quoted) {
                quotes.add(sentence);
                res.repairs.add('Added an instruction-like sentence from the notes to ignoredInstructions: "' + sentence + '"');
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ 6. next steps

    static void checkNextSteps(Map<String, Object> s, ClientContextBuilder.Context ctx, Result res) {
        List<Object> steps = (List<Object>) s.get('nextSteps');
        for (Integer i = 0; i < steps.size(); i++) {
            Map<String, Object> step = (Map<String, Object>) steps[i];
            String path = 'nextSteps[' + i + ']';
            String action = ((String) step.get('action')).trim();
            if (ctx.notes == null) {
                res.errors.add(path + ': there are no meeting notes, so there can be no next steps.');
                continue;
            }
            if (!((List<Object>) step.get('sources')).contains(ctx.notesSourceId)) {
                res.errors.add(path + ' must cite the meeting notes (' + ctx.notesSourceId + ').');
            }
            Integer[] span = clauseSpan(ctx.notes, action);
            if (span == null) {
                res.errors.add(path + ': action "' + action + '" must appear exactly once in the notes, within one clause.');
                continue;
            }
            // The owner comes from the clause itself ("PR to set up"); the action may also take the object from the
            // clause before it ("pre-sounding w/ both agencies needed, PR to set up").
            String owner = ownerFor(text(ctx.notes, span), ctx);
            String clause = text(ctx.notes, withObject(ctx.notes, span));
            if (isInjected(clause, (List<Object>) s.get('ignoredInstructions'))) {
                res.errors.add(path + ': the action is text the notes aimed at the AI, not a next step.');
                continue;
            }
            // equals(), not !=: Apex string comparison with == / != ignores case.
            if (!clause.equals(action)) {
                res.repairs.add(path + ': action "' + action + '" replaced by the full clause "' + clause + '".');
                step.put('action', clause);
            }
            if (!owner.equals((String) step.get('owner'))) {
                res.repairs.add(path + ': owner "' + step.get('owner') + '" set to "' + owner + '" from the notes.');
                step.put('owner', owner);
            }
        }
    }

    /** The full clause for an action (see clauseSpan), without the one-comma extension. Null when there is none. */
    @TestVisible
    static String clauseFor(String notes, String action) {
        Integer[] span = clauseSpan(notes, action);
        return span == null ? null : text(notes, span);
    }

    /**
     * Locates the action in the notes (exactly once) and extends it to the clause boundaries: [start, end) in notes.
     * - Comma, semicolon and newline end a clause both ways.
     * - A colon starts one, unless it sits between two digits ("9:30"); so does a spaced dash ("ratings - ...").
     * - A sentence-ending period (see isSentenceEnd) ends one both ways.
     * Returns null when the action is missing, ambiguous, or spans more than one clause.
     */
    static Integer[] clauseSpan(String notes, String action) {
        if (String.isBlank(action) || action.containsAny(',;\n')) {
            return null;
        }
        Integer at = notes.indexOf(action);
        if (at < 0 || notes.indexOf(action, at + 1) >= 0) {
            return null;
        }
        Integer actionEnd = at + action.length();
        Integer endAt = at;
        while (endAt < notes.length() && !',;\n'.contains(notes.substring(endAt, endAt + 1))) {
            if (isSentenceEnd(notes, endAt)) {
                if (endAt < actionEnd - 1) {
                    return null;           // the action runs across a sentence end
                }
                break;
            }
            endAt++;
        }
        endAt = Math.max(endAt, Math.min(actionEnd, notes.length()));
        return new Integer[]{ clauseStart(notes, at), endAt };
    }

    /** Walks back from pos to the start of its clause. */
    static Integer clauseStart(String notes, Integer pos) {
        Integer startAt = pos;
        while (startAt > 0) {
            String c = notes.substring(startAt - 1, startAt);
            if (',;\n'.contains(c) || (c == '.' && isSentenceEnd(notes, startAt - 1))) {
                break;
            }
            if (c == ':' && !(startAt >= 2 && notes.substring(startAt - 2, startAt - 1).isNumeric()
                    && startAt < notes.length() && notes.substring(startAt, startAt + 1).isNumeric())) {
                break;
            }
            // A spaced dash is a label separator like the colon ("ratings - pre-sounding ..."); "pre-sounding" is not.
            if ('-–—'.contains(c) && startAt >= 2 && notes.substring(startAt - 2, startAt - 1).isWhitespace()
                    && startAt < notes.length() && notes.substring(startAt, startAt + 1).isWhitespace()) {
                break;
            }
            startAt--;
        }
        return startAt;
    }

    /**
     * A period at i ends a sentence when whitespace (or the end of the notes) follows, unless it ends a single capital
     * letter (an initial: "S. Mendes"), a known abbreviation ("approx.", "e.g."), or sits between digits ("1.2").
     */
    @TestVisible
    static Boolean isSentenceEnd(String notes, Integer i) {
        if (notes.substring(i, i + 1) != '.') {
            return false;
        }
        if (i + 1 < notes.length() && !notes.substring(i + 1, i + 2).isWhitespace()) {
            return false;                  // "1.2", "e.g" inside "e.g.", "w/o.x"
        }
        Integer k = i;
        while (k > 0 && !notes.substring(k - 1, k).isWhitespace()) {
            k--;
        }
        String word = notes.substring(k, i).replaceAll('^[^A-Za-z0-9]+', '');   // "(approx" -> "approx"
        if (word.length() == 1 && word.isAllUpperCase()) {
            return false;
        }
        return !ABBREVIATIONS.contains(word.toLowerCase() + '.');
    }

    /**
     * An objectless clause ("PR to set up") takes the clause before it, across one comma in the same sentence:
     * "pre-sounding w/ both agencies needed, PR to set up". Anything else is returned unchanged.
     */
    static Integer[] withObject(String notes, Integer[] span) {
        if (!OBJECTLESS.matcher(text(notes, span)).matches()) {
            return span;
        }
        Integer comma = span[0] - 1;
        while (comma >= 0 && notes.substring(comma, comma + 1).isWhitespace()) {
            comma--;
        }
        if (comma <= 0 || notes.substring(comma, comma + 1) != ',') {
            return span;                   // starts a sentence, a line or the notes: nothing to borrow
        }
        return new Integer[]{ clauseStart(notes, comma), span[1] };
    }

    /** The action text a next step ends up with (clause + one-comma extension). Same steps as checkNextSteps; for tests. */
    @TestVisible
    static String actionFor(String notes, String action) {
        Integer[] span = clauseSpan(notes, action);
        return span == null ? null : text(notes, withObject(notes, span));
    }

    static String text(String notes, Integer[] span) {
        return notes.substring(span[0], span[1]).trim().removeEnd('.').trim();
    }

    /** CLAUDE.md owner rules, applied to the full clause. The model's owner is never used. */
    @TestVisible
    static String ownerFor(String clause, ClientContextBuilder.Context ctx) {
        if (TRAILING_BRACKET.matcher(clause).find()) {
            return 'Unassigned';           // "(TB)" may be the requester or the recipient
        }
        if (WE_OWNER.matcher(clause).find()) {
            return 'Deal team';
        }
        Integer to = clause.indexOf(' to ');
        if (to <= 0 || to + 4 >= clause.length() || !clause.substring(to + 4, to + 5).isAllLowerCase()) {
            return 'Unassigned';
        }
        // X in "X to verb" counts only if it is a known person or a known team; otherwise "write to the CFO" would make
        // "write" the owner.
        String before = clause.left(to).trim();
        List<String> words = before.split('\\s+');
        String last = words[words.size() - 1];
        for (String team : TEAM_WORDS) {
            if (last.equalsIgnoreCase(team)) {
                return team;               // "legal to check ..." -> legal. Before initials: "ECM" looks like initials.
            }
        }
        if (INITIALS.matcher(last).matches()) {
            return resolveInitials(last, ctx);
        }
        String name = knownName(before, ctx);
        return name == null ? 'Unassigned' : name;
    }

    static String resolveInitials(String initials, ClientContextBuilder.Context ctx) {
        Set<String> hits = new Set<String>();
        for (String name : people(ctx)) {
            List<String> parts = name.split('\\s+');
            String all = '';
            for (String p : parts) {
                all += p.left(1).toUpperCase();
            }
            String firstLast = parts[0].left(1).toUpperCase() + parts[parts.size() - 1].left(1).toUpperCase();
            if (all == initials || firstLast == initials) {
                hits.add(name);
            }
        }
        return hits.size() == 1 ? new List<String>(hits)[0] : 'Unassigned';
    }

    /** A person from attendees/contacts whose full name ends the text before " to ". */
    static String knownName(String before, ClientContextBuilder.Context ctx) {
        for (String name : people(ctx)) {
            if (before == name || before.endsWith(' ' + name)) {
                return name;
            }
        }
        return null;
    }

    static List<String> people(ClientContextBuilder.Context ctx) {
        Set<String> names = new Set<String>();
        for (String a : ctx.attendees) {
            String n = a.replaceAll('\\s*\\(.*\\)\\s*', '').trim();   // "Margaret Okafor (CFO)" -> "Margaret Okafor"
            if (n.contains(' ') && !n.toLowerCase().contains('team')) {
                names.add(n);
            }
        }
        names.addAll(ctx.contactNames);
        return new List<String>(names);
    }

    static Boolean isInjected(String clause, List<Object> quotes) {
        if (matchesInjection(clause)) {
            return true;
        }
        String c = collapse(clause);
        for (Object q : quotes) {
            String cq = collapse((String) q);
            if (cq.length() > 0 && (cq.contains(c) || c.contains(cq))) {
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------------------------------------ 7. placeholders

    static void removePlaceholders(Map<String, Object> s, List<String> repairs) {
        for (String k : STRING_ARRAYS) {
            List<Object> kept = new List<Object>();
            for (Object o : (List<Object>) s.get(k)) {
                if (PLACEHOLDER.matcher((String) o).matches()) {
                    repairs.add('Removed placeholder "' + o + '" from ' + k + '.');
                } else {
                    kept.add(o);
                }
            }
            s.put(k, kept);
        }
    }

    // ------------------------------------------------------------------------------------------------ helpers

    public static Boolean matchesInjection(String text) {
        if (String.isBlank(text)) {
            return false;
        }
        for (Pattern p : INJECTION_PATTERNS) {
            if (p.matcher(text).find()) {
                return true;
            }
        }
        return false;
    }

    /** Sentences of the text that match an injection pattern (split on newlines and sentence ends). */
    @TestVisible
    static List<String> injectionSentences(String text) {
        List<String> out = new List<String>();
        for (String sentence : sentences(text)) {
            if (matchesInjection(sentence)) {
                out.add(sentence.trim().removeEnd('.'));
            }
        }
        return out;
    }

    static String withoutInjection(String text) {
        List<String> kept = new List<String>();
        for (String sentence : sentences(text)) {
            if (!matchesInjection(sentence)) {
                kept.add(sentence);
            }
        }
        return String.join(kept, '\n');
    }

    static List<String> sentences(String text) {
        List<String> out = new List<String>();
        if (String.isBlank(text)) {
            return out;
        }
        for (String line : text.split('\n')) {
            for (String sentence : line.split('(?<=[.!?])\\s+')) {
                if (String.isNotBlank(sentence)) {
                    out.add(sentence);
                }
            }
        }
        return out;
    }

    static String collapse(String s) {
        return s == null ? '' : s.normalizeSpace();
    }

    private class FreeText {
        String path;
        String text;
        FreeText(String path, String text) {
            this.path = path;
            this.text = text;
        }
    }

    /** The model-written prose fields: checked for source ids and amounts. */
    static List<FreeText> freeText(Map<String, Object> s) {
        List<FreeText> out = new List<FreeText>{ new FreeText('executiveSummary', (String) s.get('executiveSummary')) };
        for (String arrayKey : FREE_TEXT_ITEMS.keySet()) {
            List<Object> items = (List<Object>) s.get(arrayKey);
            for (Integer i = 0; i < items.size(); i++) {
                String field = FREE_TEXT_ITEMS.get(arrayKey);
                out.add(new FreeText(arrayKey + '[' + i + '].' + field, (String) ((Map<String, Object>) items[i]).get(field)));
            }
        }
        List<Object> gaps = (List<Object>) s.get('dataGaps');
        for (Integer i = 0; i < gaps.size(); i++) {
            out.add(new FreeText('dataGaps[' + i + ']', (String) gaps[i]));
        }
        return out;
    }
}
