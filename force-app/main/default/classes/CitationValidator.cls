/**
 * Checks and repairs the model's JSON for Meeting_Prep_QA (docs/meeting_prep_schema.json) against the account context the
 * model saw. Same style as SummaryValidator, and it reuses SummaryValidator's money parser, injection patterns,
 * placeholder rule, initials logic and amount-conflict check.
 *
 * Outcomes:
 * - VALID       the answer passes every check unchanged.
 * - REPAIRABLE  code fixed it deterministically (fence, placeholders, duplicate source ids, whitespace, a missed injection
 *               added to ignoredInstructions). answer/json hold the fix.
 * - INVALID     a claim code can't verify; errors say why. The caller retries once, then says it couldn't produce a
 *               verified answer. Never an uncited answer.
 *
 * Citations are checked against the cited sources' text, with one widening: a meeting's notes block and its header line
 * (name, date, attendees) are one unit, and so are a research note's line and body. The model may cite only the notes and
 * still use the meeting's date or an attendee's full name from the header (prep v2 a: Priya Raman / Margaret Okafor).
 *
 * Block: every sentence has a source; ids exist; no ids in text; every amount equals an amount in a cited source; every
 * other number (digit runs: "7 versus 10 year" ~ "7 vs 10yr") appears in a cited source; every month/day date matches a
 * date in a cited source; every known person or opportunity name is in a cited source (or its initials there resolve to
 * that person, Option A's rule); no injection text; missing[] only uses numbers that are somewhere in the context;
 * ignoredInstructions quotes are real context text.
 * Offline eval only: whether a cited source supports the sentence's meaning; unknown names; wording.
 *
 * Pure Apex: no SOQL, no DML.
 */
public with sharing class CitationValidator {

    public enum Outcome { VALID, REPAIRABLE, INVALID }

    public class Result {
        public Outcome outcome;
        public Map<String, Object> answer;     // the final answer (repaired if needed); null when INVALID
        public String json;
        public List<String> repairs = new List<String>();
        public List<String> errors = new List<String>();
    }

    public static final Integer MAX_SENTENCES = 5;
    static final Set<String> TOP_KEYS = new Set<String>{ 'answerable', 'sentences', 'missing', 'ignoredInstructions' };
    static final Set<String> SENTENCE_KEYS = new Set<String>{ 'text', 'sources' };
    static final Pattern SOURCE_ID = Pattern.compile('^S[0-9]+$');
    static final Pattern DIGITS = Pattern.compile('\\d+(?:[.,]\\d+)*');
    static final Pattern ISO_DATE = Pattern.compile('\\b(\\d{4})-(\\d{2})-(\\d{2})\\b');
    // Whole month names or 3-letter abbreviations only, so "2 marketing" or "maybe" never read as dates.
    static final String MONTHS = '(january|february|march|april|may|june|july|august|september|october|november|december'
        + '|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\\.?';
    static final Pattern MONTH_DAY = Pattern.compile('(?i)\\b' + MONTHS + '\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b');
    static final Pattern DAY_MONTH = Pattern.compile('(?i)\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?' + MONTHS + '(?![a-z])');
    static final List<String> MONTH_KEYS = new List<String>{ 'jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec' };

    // ------------------------------------------------------------------------------------------------ entry point

    public static Result validate(String raw, ClientContextBuilder.Context ctx) {
        return validate(raw, ctx, new Set<String>());
    }

    /**
     * otherClientNames: names of other accounts and other clients' open opportunities the banker can see (the caller
     * looks them up in USER_MODE; this class runs no SOQL). A sentence that names one of them must cite a source that
     * names it too. The selected client's own name is exempt: the whole answer is about that client. An empty set
     * disables the check, so callers must pass the real list (MeetingPrepService tests prove it end to end).
     */
    public static Result validate(String raw, ClientContextBuilder.Context ctx, Set<String> otherClientNames) {
        Result res = new Result();
        Map<String, Object> a = parse(raw, res);
        if (a != null) {
            checkSchema(a, res.errors);
        }
        if (res.errors.isEmpty()) {
            tidy(a, res.repairs);
            checkShape(a, res.errors);
        }
        if (res.errors.isEmpty()) {
            checkSentences(a, ctx, otherClientNames == null ? new Set<String>() : otherClientNames, res.errors);
            checkMissing(a, ctx, res.errors);
            checkIgnoredInstructions(a, ctx, res);
        }
        if (!res.errors.isEmpty()) {
            res.outcome = Outcome.INVALID;
            return res;
        }
        res.outcome = res.repairs.isEmpty() ? Outcome.VALID : Outcome.REPAIRABLE;
        res.answer = a;
        res.json = JSON.serialize(a);
        return res;
    }

    // ------------------------------------------------------------------------------------------------ parse and schema

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
        try {
            Object parsed = JSON.deserializeUntyped(text);
            if (parsed instanceof Map<String, Object>) {
                return (Map<String, Object>) parsed;
            }
            res.errors.add('Output is not a JSON object.');
        } catch (Exception e) {
            res.errors.add('Invalid JSON: ' + e.getMessage());
        }
        return null;
    }

    static void checkSchema(Map<String, Object> a, List<String> errors) {
        for (String k : a.keySet()) {
            if (!TOP_KEYS.contains(k)) {
                errors.add('Unknown key "' + k + '".');
            }
        }
        for (String k : TOP_KEYS) {
            if (!a.containsKey(k)) {
                errors.add('Missing key "' + k + '".');
            }
        }
        if (!errors.isEmpty()) {
            return;
        }
        if (!(a.get('answerable') instanceof Boolean)) {
            errors.add('"answerable" must be true or false.');
        }
        for (String k : new List<String>{ 'missing', 'ignoredInstructions' }) {
            if (!(a.get(k) instanceof List<Object>)) {
                errors.add('"' + k + '" must be an array of strings.');
                continue;
            }
            for (Object o : (List<Object>) a.get(k)) {
                if (!(o instanceof String)) {
                    errors.add('"' + k + '" must contain only strings.');
                }
            }
        }
        if (!(a.get('sentences') instanceof List<Object>)) {
            errors.add('"sentences" must be an array.');
            return;
        }
        List<Object> sentences = (List<Object>) a.get('sentences');
        for (Integer i = 0; i < sentences.size(); i++) {
            String path = 'sentences[' + i + ']';
            if (!(sentences[i] instanceof Map<String, Object>)) {
                errors.add(path + ' must be an object.');
                continue;
            }
            Map<String, Object> s = (Map<String, Object>) sentences[i];
            for (String k : s.keySet()) {
                if (!SENTENCE_KEYS.contains(k)) {
                    errors.add(path + ': unknown key "' + k + '".');
                }
            }
            if (!(s.get('text') instanceof String) || String.isBlank((String) s.get('text'))) {
                errors.add(path + '.text must be a non-empty string.');
            }
            if (!(s.get('sources') instanceof List<Object>)) {
                errors.add(path + '.sources must be an array of source ids.');
                continue;
            }
            for (Object id : (List<Object>) s.get('sources')) {
                if (!(id instanceof String) || !SOURCE_ID.matcher((String) id).matches()) {
                    errors.add(path + '.sources: "' + id + '" is not a source id like "S3".');
                }
            }
        }
    }

    /** Repairs that change nothing a banker relies on: whitespace, placeholders, duplicate source ids. */
    static void tidy(Map<String, Object> a, List<String> repairs) {
        for (String k : new List<String>{ 'missing', 'ignoredInstructions' }) {
            List<Object> kept = new List<Object>();
            for (Object o : (List<Object>) a.get(k)) {
                if (SummaryValidator.isPlaceholder((String) o)) {
                    repairs.add('Removed placeholder "' + o + '" from ' + k + '.');
                } else {
                    kept.add(((String) o).trim());
                }
            }
            a.put(k, kept);
        }
        List<Object> sentences = (List<Object>) a.get('sentences');
        for (Integer i = 0; i < sentences.size(); i++) {
            Map<String, Object> s = (Map<String, Object>) sentences[i];
            s.put('text', ((String) s.get('text')).trim());
            List<Object> ids = (List<Object>) s.get('sources');
            List<Object> unique = new List<Object>(new Set<Object>(ids));
            if (unique.size() < ids.size()) {
                repairs.add('sentences[' + i + ']: removed duplicate source ids.');
                List<Object> ordered = new List<Object>();
                for (Object id : ids) {
                    if (!ordered.contains(id)) {
                        ordered.add(id);
                    }
                }
                s.put('sources', ordered);
            }
        }
    }

    static void checkShape(Map<String, Object> a, List<String> errors) {
        Boolean answerable = (Boolean) a.get('answerable');
        Integer n = ((List<Object>) a.get('sentences')).size();
        if (answerable && (n == 0 || n > MAX_SENTENCES)) {
            errors.add('An answer must have 1 to ' + MAX_SENTENCES + ' sentences (has ' + n + ').');
        }
        if (!answerable && n > 0) {
            errors.add('answerable is false, so there must be no sentences (has ' + n + ').');
        }
        if (!answerable && ((List<Object>) a.get('missing')).isEmpty()) {
            errors.add('answerable is false, so "missing" must say what is not in the CRM record.');
        }
    }

    // ------------------------------------------------------------------------------------------------ sentences

    static void checkSentences(Map<String, Object> a, ClientContextBuilder.Context ctx, Set<String> otherClientNames,
            List<String> errors) {
        List<Object> sentences = (List<Object>) a.get('sentences');
        Map<String, Set<String>> units = units(ctx);
        String accountName = accountName(ctx);
        for (Integer i = 0; i < sentences.size(); i++) {
            Map<String, Object> s = (Map<String, Object>) sentences[i];
            String path = 'sentences[' + i + ']';
            String text = (String) s.get('text');
            List<Object> ids = (List<Object>) s.get('sources');
            if (ids.isEmpty()) {
                errors.add(path + ' has no source: every sentence must cite at least one.');
                continue;
            }
            Set<String> cited = new Set<String>();
            Boolean unknown = false;
            for (Object id : ids) {
                if (!ctx.sources.containsKey((String) id)) {
                    errors.add(path + ': source "' + id + '" is not in the context.');
                    unknown = true;
                } else {
                    cited.addAll(units.get((String) id));
                }
            }
            if (unknown) {
                continue;
            }
            if (SummaryValidator.mentionsSourceId(text)) {
                errors.add(path + ': source ids belong in "sources", not in the sentence text.');
            }
            if (SummaryValidator.matchesInjection(text)) {
                errors.add(path + ': the sentence repeats text aimed at the AI.');
            }
            String citedText = textOf(cited, ctx);
            checkAmounts(path, text, citedText, errors);
            checkNumbers(path, text, citedText, errors);
            checkDates(path, text, citedText, errors);
            checkNames(path, text, citedText, accountName, ctx, errors);
            checkProjectCodeNames(path, text, citedText, ctx, errors);
            checkOtherNames(path, text, citedText, accountName, otherClientNames, errors);
        }
    }

    static final Pattern PROJECT_CODE_NAME = Pattern.compile('(?i)^Project\\s+([A-Za-z0-9&]{3,})\\b');

    /**
     * Project code names of the selected client's open deals ("Atlas" from "Project Atlas - ..."): the code word, whole
     * word, any case, must be in a cited source. Owner decision (2026-10-13): only "Project <Word>" names; other words in
     * deal names ("Notes", "Lines") are ordinary words and are not checked.
     */
    static void checkProjectCodeNames(String path, String text, String citedText, ClientContextBuilder.Context ctx,
            List<String> errors) {
        for (ClientContextBuilder.ContextSection sec : ctx.sections) {
            if (sec.title != 'OPEN OPPORTUNITIES') {
                continue;
            }
            for (ClientContextBuilder.ContextLine opp : sec.lines) {
                String code = projectCodeName(opp.name);
                if (code != null && wordIn(code, text) && !wordIn(code, citedText)) {
                    errors.add(path + ': the deal name "' + code + '" is not in the cited sources.');
                }
            }
        }
    }

    /**
     * Other clients and other clients' deals named in the sentence must be named in a cited source too: cross-client
     * leakage the context can't support. The names come from the caller (USER_MODE lookup; this class runs no SOQL):
     * account names are keyed on their first word ("Northwind"), "Project <Word>" deal names on the code word ("Keel").
     */
    static void checkOtherNames(String path, String text, String citedText, String accountName, Set<String> otherNames,
            List<String> errors) {
        String selectedKey = nameKey(accountName);
        for (String other : otherNames) {
            String key = nameKey(other);
            if (key == null || key.equalsIgnoreCase(selectedKey)) {
                continue;
            }
            if (wordIn(key, text) && !wordIn(key, citedText)) {
                errors.add(path + ': names "' + other + '", which belongs to another client and is not in the cited sources.');
            }
        }
    }

    /** "Keel" for "Project Keel - Acquisition of ...", otherwise null. */
    public static String projectCodeName(String dealName) {
        if (String.isBlank(dealName)) {
            return null;
        }
        Matcher m = PROJECT_CODE_NAME.matcher(dealName.trim());
        return m.find() ? m.group(1) : null;
    }

    /** The word that identifies a name in conversation: a project's code word, else the first word (3+ characters). */
    public static String nameKey(String name) {
        if (String.isBlank(name)) {
            return null;
        }
        String code = projectCodeName(name);
        if (code != null) {
            return code;
        }
        String first = name.trim().split('\\s+')[0].replaceAll('[^A-Za-z0-9&]', '');
        return first.length() >= 3 ? first : null;
    }

    /** The names (accounts, deals) the text mentions, by the same keys the citation check uses. */
    public static List<String> namesMentioned(String text, Set<String> names) {
        List<String> out = new List<String>();
        for (String n : names) {
            String key = nameKey(n);
            if (key != null && wordIn(key, text)) {
                out.add(n);
            }
        }
        out.sort();
        return out;
    }

    public static Boolean wordIn(String word, String text) {
        return Pattern.compile('(?i)(?<![A-Za-z0-9])' + Pattern.quote(word) + '(?![A-Za-z0-9])').matcher(text).find();
    }

    static void checkAmounts(String path, String text, String citedText, List<String> errors) {
        Set<Long> allowed = new Set<Long>(SummaryValidator.parseMoney(citedText));
        for (Long v : SummaryValidator.parseMoney(text)) {
            if (!allowed.contains(v)) {
                errors.add(path + ': amount ' + v + ' is not in the cited sources.');
            }
        }
    }

    /** Numbers other than amounts, compared as digit runs ("7 versus 10 year" ~ "7 vs 10yr", "08" ~ "8", "1,200" ~ "1200"). */
    static void checkNumbers(String path, String text, String citedText, List<String> errors) {
        Set<String> allowed = digitRuns(citedText);
        for (String run : digitRuns(SummaryValidator.withoutMoney(text))) {
            if (!allowed.contains(run)) {
                errors.add(path + ': the number ' + run + ' is not in the cited sources.');
            }
        }
    }

    static void checkDates(String path, String text, String citedText, List<String> errors) {
        Set<String> allowed = monthDays(citedText);
        for (String md : monthDays(text)) {
            if (!allowed.contains(md)) {
                errors.add(path + ': the date ' + md + ' (month-day) is not in the cited sources.');
            }
        }
    }

    /**
     * Known people (attendees, contacts) and open-opportunity names in the sentence must be in a cited source. A person
     * also passes when their initials appear in the cited text and resolve to exactly that person (Option A's rule).
     * The selected client's own name is exempt: the whole answer is about that client.
     */
    static void checkNames(String path, String text, String citedText, String accountName, ClientContextBuilder.Context ctx,
            List<String> errors) {
        String lowerText = text.toLowerCase();
        String lowerCited = citedText.toLowerCase();
        List<String> people = SummaryValidator.peopleIn(ctx);
        for (String person : people) {
            if (!lowerText.contains(person.toLowerCase()) || lowerCited.contains(person.toLowerCase())) {
                continue;
            }
            if (!initialsCited(person, people, citedText)) {
                errors.add(path + ': "' + person + '" is not in the cited sources.');
            }
        }
        for (ClientContextBuilder.ContextSection sec : ctx.sections) {
            if (sec.title != 'OPEN OPPORTUNITIES') {
                continue;
            }
            for (ClientContextBuilder.ContextLine opp : sec.lines) {
                if (opp.name != null && !opp.name.equalsIgnoreCase(accountName) && lowerText.contains(opp.name.toLowerCase())
                        && !lowerCited.contains(opp.name.toLowerCase())) {
                    errors.add(path + ': the deal name "' + opp.name + '" is not in the cited sources.');
                }
            }
        }
    }

    static Boolean initialsCited(String person, List<String> people, String citedText) {
        Matcher m = Pattern.compile('\\b[A-Z]{2,3}\\b').matcher(citedText);
        while (m.find()) {
            String initials = m.group();
            if (!SummaryValidator.initialsMatch(initials, person)) {
                continue;
            }
            Integer hits = 0;
            for (String p : people) {
                hits += SummaryValidator.initialsMatch(initials, p) ? 1 : 0;
            }
            if (hits == 1) {
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------------------------------------ missing, ignored

    /** missing[] is banker-facing LLM text: no numbers or amounts that are not somewhere in the context, no injection. */
    static void checkMissing(Map<String, Object> a, ClientContextBuilder.Context ctx, List<String> errors) {
        List<Object> missing = (List<Object>) a.get('missing');
        Set<Long> amounts = new Set<Long>(SummaryValidator.parseMoney(withoutInjection(ctx)));
        Set<String> runs = digitRuns(withoutInjection(ctx));
        for (Integer i = 0; i < missing.size(); i++) {
            String m = (String) missing[i];
            String path = 'missing[' + i + ']';
            if (SummaryValidator.matchesInjection(m)) {
                errors.add(path + ': repeats text aimed at the AI.');
            }
            if (SummaryValidator.mentionsSourceId(m)) {
                errors.add(path + ': source ids don\'t belong in banker-facing text.');
            }
            for (Long v : SummaryValidator.parseMoney(m)) {
                if (!amounts.contains(v)) {
                    errors.add(path + ': amount ' + v + ' is not in the context.');
                }
            }
            for (String run : digitRuns(SummaryValidator.withoutMoney(m))) {
                if (!runs.contains(run)) {
                    errors.add(path + ': the number ' + run + ' is not in the context.');
                }
            }
        }
    }

    /** Quotes must be real context text; injection sentences the model missed are added (repair), never dropped. */
    static void checkIgnoredInstructions(Map<String, Object> a, ClientContextBuilder.Context ctx, Result res) {
        List<Object> quotes = (List<Object>) a.get('ignoredInstructions');
        String all = ctx.text.normalizeSpace();
        for (Integer i = 0; i < quotes.size(); i++) {
            if (!all.contains(((String) quotes[i]).normalizeSpace())) {
                res.errors.add('ignoredInstructions[' + i + '] is not text from the context.');
            }
        }
        for (String id : ctx.sourceText.keySet()) {
            if (!isUntrusted(ctx.sources.get(id))) {
                continue;
            }
            for (String sentence : SummaryValidator.injectionSentences(ctx.sourceText.get(id))) {
                Boolean quoted = false;
                for (Object q : quotes) {
                    String cq = ((String) q).normalizeSpace();
                    quoted |= cq.contains(sentence.normalizeSpace()) || sentence.normalizeSpace().contains(cq);
                }
                if (!quoted) {
                    quotes.add(sentence);
                    res.repairs.add('Added an instruction-like sentence from the context to ignoredInstructions: "' + sentence + '"');
                }
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ review items

    /**
     * Option A's amount-conflict check over every recent meeting's notes in the account context, whatever the answer
     * cites: "Notes and CRM disagree: MTG-0019 (2026-10-09) notes state ~$1.1bn for Project Keel ...; CRM amount is
     * USD 850,000,000. ..." One line per meeting and deal.
     */
    public static List<String> amountConflictReviewItems(ClientContextBuilder.Context ctx) {
        List<String> out = new List<String>();
        for (String id : sortedIds(ctx.sources.keySet())) {
            if (!ctx.sources.get(id).startsWith('Client_Meeting__c.Meeting_Notes__c:')) {
                continue;
            }
            String label = meetingLabel(ctx.sources.get(id).substringAfter(':'), ctx);
            for (SummaryValidator.AmountConflict c : SummaryValidator.amountConflictsIn(ctx.sourceText.get(id), ctx)) {
                out.add(AiActionSupport.REVIEW_CONFLICT + c.describe(label));
            }
        }
        return out;
    }

    /** "MTG-0019 (2026-10-09)" from the meeting's header line. */
    static String meetingLabel(String meetingId, ClientContextBuilder.Context ctx) {
        for (ClientContextBuilder.ContextSection sec : ctx.sections) {
            for (ClientContextBuilder.ContextLine l : sec.lines) {
                if (('Client_Meeting__c:' + meetingId).equals(ctx.sources.get(l.id))) {
                    String day = l.body.substringAfter('Date: ').substringBefore(' |');
                    return l.name + (String.isBlank(day) ? '' : ' (' + day + ')');
                }
            }
        }
        return 'Meeting';
    }

    // ------------------------------------------------------------------------------------------------ helpers

    /**
     * Each source id -> the ids checked with it. A meeting's notes and its header line are one unit (same record Id), as
     * are a research note's line and body; every other source stands alone.
     */
    @TestVisible
    static Map<String, Set<String>> units(ClientContextBuilder.Context ctx) {
        Map<String, Set<String>> byRecord = new Map<String, Set<String>>();
        for (String id : ctx.sources.keySet()) {
            String ref = ctx.sources.get(id);
            String recordKey = (ref.startsWith('Client_Meeting__c') || ref.startsWith('Research_Note__c')) ? ref.substringAfterLast(':') : id;
            if (!byRecord.containsKey(recordKey)) {
                byRecord.put(recordKey, new Set<String>());
            }
            byRecord.get(recordKey).add(id);
        }
        Map<String, Set<String>> out = new Map<String, Set<String>>();
        for (Set<String> unit : byRecord.values()) {
            for (String id : unit) {
                out.put(id, unit);
            }
        }
        return out;
    }

    static String textOf(Set<String> ids, ClientContextBuilder.Context ctx) {
        List<String> parts = new List<String>();
        for (String id : ids) {
            parts.add(ctx.sourceText.get(id));
        }
        return String.join(parts, '\n');
    }

    @TestVisible
    static Set<String> digitRuns(String text) {
        Set<String> out = new Set<String>();
        if (String.isBlank(text)) {
            return out;
        }
        Matcher m = DIGITS.matcher(text);
        while (m.find()) {
            String run = m.group().replace(',', '');
            String whole = run.substringBefore('.').replaceFirst('^0+(?=\\d)', '');
            out.add(run.contains('.') ? whole + '.' + run.substringAfter('.') : whole);
        }
        return out;
    }

    /** Month-day keys ("10-08") for ISO dates and written dates ("Oct 8", "8 October", "October 8th"). */
    @TestVisible
    static Set<String> monthDays(String text) {
        Set<String> out = new Set<String>();
        if (String.isBlank(text)) {
            return out;
        }
        Matcher iso = ISO_DATE.matcher(text);
        while (iso.find()) {
            out.add(iso.group(2) + '-' + iso.group(3));
        }
        Matcher md = MONTH_DAY.matcher(text);
        while (md.find()) {
            out.add(key(md.group(1), md.group(2)));
        }
        Matcher dm = DAY_MONTH.matcher(text);
        while (dm.find()) {
            out.add(key(dm.group(2), dm.group(1)));
        }
        return out;
    }

    static String key(String month, String day) {
        Integer m = MONTH_KEYS.indexOf(month.toLowerCase().left(3)) + 1;
        return String.valueOf(m).leftPad(2, '0') + '-' + day.leftPad(2, '0');
    }

    static Boolean isUntrusted(String ref) {
        return ref.startsWith('Client_Meeting__c.Meeting_Notes__c:') || ref.startsWith('Research_Note__c.Body__c:')
            || ref.startsWith('Task:') || ref.startsWith('Event:');
    }

    /** The context text without injection lines and without the [S#] tags (so tag numbers don't count as facts). */
    static String withoutInjection(ClientContextBuilder.Context ctx) {
        List<String> kept = new List<String>();
        for (String line : ctx.text.split('\n')) {
            if (!SummaryValidator.matchesInjection(line)) {
                kept.add(line.replaceAll('\\[?\\bS\\d+\\b\\]?', ' '));
            }
        }
        return String.join(kept, '\n');
    }

    static String accountName(ClientContextBuilder.Context ctx) {
        for (ClientContextBuilder.ContextSection sec : ctx.sections) {
            if (sec.title == 'CLIENT' && !sec.lines.isEmpty()) {
                return sec.lines[0].name;
            }
        }
        return '';
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
}
