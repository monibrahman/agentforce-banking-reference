# Reusable pattern: Context → Template → Validate → Fallback → Log

For the SI building the 30+ agent backlog. This build ships two capabilities on the same pattern: Client Meeting Summary
(Option A) and Meeting Prep Q&A (Option B). The second one reused the first one's plumbing (`AiActionSupport`, the context
builder, the gateway, the test kit). What follows is what that reuse looked like in practice, with the real class names
and the mistakes that shaped each rule.

**Design rule: the LLM writes. Code gathers the facts and checks the output.** A banker never sees invented or broken
content: they see validated model output, a deterministic fallback, or a clear message.

```
Banker / agent
   │  Find action (resolves the record; sets a guard variable)
   ▼
Invocable service (with sharing)            e.g. ClientSummaryService, MeetingPrepService
   ├─ 1. Context   ClientContextBuilder      USER_MODE queries → source-tagged text [S1]..[Sn], budget, untrusted blocks
   ├─ 2. Template  ILlmGateway               Prompt Builder Flex template, strict JSON out, frozen version
   ├─ 3. Validate  SummaryValidator /        block → retry once; repair → status (Repaired); offline-only checks
   │               CitationValidator
   ├─ 4. Fallback  data-only or message-only  never an uncited or unchecked answer
   └─ 5. Log       AiActionSupport.logRow    one AI_Generation_Log__c row per request, system mode
   ▼
Banker-facing outputs (status, text, review items, message, code-built link line), shown verbatim
(intended; see the display-layer limit in section 2)
```

## 1. The five stages and their contracts

### 1. Context
- **Class:** `ClientContextBuilder`. Meeting level: `build(meetingId)` and `buildContext(meetingId)`. Account level:
  `buildAccountContext(accountId)`. Both return `ClientContextBuilder.Context`: `text` (what the model sees), `sources`
  (S# to the record), `sourceText` (S# to the exact text shown), `amounts`, `attendees`, `contactNames`, `chars`.
- **Contract:**
  - Every query is `WITH USER_MODE`, so the model only gets what the banker can see.
  - Every fact carries a source id.
  - Banker-typed text (notes, activity, research bodies) sits inside BEGIN/END UNTRUSTED delimiters and is labelled as data.
  - A character budget (12,000) drops the lowest-priority lines first and lists every cut under CONTEXT NOTES.
- **Grounding invocables are unbound** (no `capabilityType`), so one class can ground several templates (BUILD_LOG
  2026-10-11, capabilityType row). Apex allows one invocable per class, so each extra grounding shape gets a tiny class
  (`AccountContextAction`).
- **A frozen template's input must not move.** When the account level was added, the meeting-level text was compared by
  SHA-256 on MTG-0013..0019 before and after: identical (BUILD_LOG 2026-10-13, step 2).

### 2. Template
- **Built in Prompt Builder** (Flex) by the owner, then retrieved. Output is strict JSON to a schema in `docs/`
  (`summary_schema.json`, `meeting_prep_schema.json`). The version is frozen once adopted (`_5`, `_2`).
- **Called only through `ILlmGateway`:** `generate(templateApiName, recordId)` and `generate(templateApiName, Map<String,
  Object> inputs)` for named inputs (`Input:Account` as a record, `Input:Question` as text). Production uses
  `PromptTemplateGateway` (`ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate`). It returns `LlmResponse`: `text`,
  `resolvedPrompt`, `requestId`.
- **The API returns no template version** (spike 2026-10-12), so each service holds a `TEMPLATE_VERSION` constant. Update it
  whenever the active version changes, and re-run the offline eval.
- **Drift check:** the CONTEXT block in `resolvedPrompt` is compared with `ctx.text`, and any difference is logged. Validation
  is always against `ctx`.

### 3. Validate
- **Classes:** `SummaryValidator.validate(raw, ctx)` and `CitationValidator.validate(raw, ctx, otherClientNames)`. Both return
  `Result` with `outcome` (VALID, REPAIRABLE, INVALID), `json`, `repairs` and `errors`.
- **Three tiers. Decide the tier for each rule up front:**

| Tier | What happens | Examples from this build |
| --- | --- | --- |
| Block | Retry once, then fall back | Invalid JSON; a source id not in the context; an amount, number, date or known name not in a cited source; an injected instruction becoming a next step; another client's name not in a cited source |
| Repair | The fix is applied and the status says "(Repaired)" | Next step replaced by the full clause from the notes; owner recomputed by code; placeholders removed; amount conflicts added by code (MTG-0019) |
| Offline only | Measured on the test set, not checked at runtime | Wording and attribution ("agreed" for "needed", BA-17; "Henrik Aalto said", BA-20) |

- **Retry = a plain resample** of the same frozen template, with no feedback. The remaining errors were run-to-run
  variance. Upgrade to a feedback retry only if the offline eval shows a failure that repeats.
- **Recall the prompt gives up for precision comes back from code.** The v4 prompt was tuned to avoid false conflicts and
  missed the real one in MTG-0019. A deterministic amount-conflict check now adds it (BUILD_LOG 2026-10-12, conflict row).

### 4. Fallback
- **Error classification:** `AiActionSupport.classify(e)` sorts errors into PERMISSION, CONFIGURATION or TRANSIENT.
  Only TRANSIENT errors and invalid output are retried. Each category has its own banker-facing message (BUILD_LOG
  2026-10-12, banker test A: a permission error had been retried and reported as "did not pass the checks").
- **The fallback content depends on the risk:**
  - Summary: a data-only summary from `ctx` (`SummaryRenderer.fallbackHtml`) under the banner "AI summary unavailable;
    data-only summary".
  - Q&A: a message only ("I couldn't produce a verified answer..."). A list of facts would look like an answer.

### 5. Log
- **`AiActionSupport.logRow(...)` and `insertLogs`** write one `AI_Generation_Log__c` row per request, in system mode, so
  logging never depends on the banker's permissions. Each row records `Capability__c`, template name and version, status,
  attempts, validation errors and notes (error category first), latency, context chars and every raw output.
- **The log holds raw client data:** OWD Private, read only through the `AI_Ops` permission set. Bankers can't read it, so
  no Message may point to it (BUILD_LOG 2026-10-13, BA-02 "(see the log)").
- **Order inside the transaction:** every LLM call (and retry) for every record runs before any DML. Each record then
  saves under its own savepoint, and the log rows are written last.

## 2. Rules learned (each one came from a failure)

| Rule | Why (evidence) |
| --- | --- |
| **Links come from code**: absolute, plain text, on their own line ("Open MTG-0019: https://..."), built by `AiActionSupport.openLine`. Never ask the LLM to write or format a link. | BA-01: "use the link below" with no link. BA-13: the agent's own markdown link carried MTG-0014's Id under MTG-0019's name. Markdown doesn't render in action output (BUILD_LOG 2026-10-13, agent run 2) |
| **Every Message is banker-facing** ("Tell me ..."). Agent guidance goes only in action and output descriptions. `assertBankerFacing` checks every reachable path. | BA-15 rerun: "Ask the banker for the client name..." was shown to the banker verbatim (BUILD_LOG 2026-10-13) |
| **Verbatim display, and its limit.** Descriptions and instructions say "show exactly as returned". It works most of the time, not always: BA-19 dropped a code-written prefix and BA-24 replayed an earlier result as new. So anything that must be verifiable goes into the code-written output, like the save time in Generate's Message (8f754b8; verified in the BA-24 rerun, log a02gK00000SjfOfQAJ). | BUILD_LOG 2026-10-13, agent v5 run 1 and the BA-24 rerun. Production fix: a custom Lightning Type renderer |
| **Inputs the agent fills from a variable are Text, validated in code** (`AiActionSupport.validId(raw, SObjectType)`). | Agent Builder couldn't bind a Text variable to an `Id` input: "variable is not found" (BUILD_LOG 2026-10-13) |
| **Guard variable: set, available when, bound, cleared.** The Find action sets `selected_meeting_id` (or `selected_account_id`) from its output. The AI action is `available when @variables.selected_meeting_id != ""`, takes its input `with meetingId = @variables.selected_meeting_id`, and clears it with `set @variables.selected_meeting_id = ""`. The record Id never comes from the LLM. | BA-12: after summarizing MTG-0019, "now summarize MTG-0014" ran Find again and generated for MTG-0014's Id, with no carry-over from MTG-0019 (runs 2 and 4). BA-24, v5 run 1: the clear after Generate made a second Generate unavailable, so "Yes" could not regenerate from a stale selection (the agent's replay of the earlier text is a display issue, see the next rule) |
| **`""`, never null**, for "no selection". The Find action returns `""` unless exactly one record matches. | Agent Script doesn't define how null compares to `""` (BUILD_LOG 2026-10-13, snippet review) |
| **Diff the deployed agent after every Script-view change.** Generate the whole script and don't paste fragments. A diff catches human edits as well as tool behaviour. | In v2 the owner removed the `available when` line while isolating the Preview hang (BA-11), and it wasn't restored. Nothing in the UI flagged it; the bundle diff after run 3 caught it, and v3 restored it (BUILD_LOG 2026-10-13, v2/v3 rows and the correction row). v4 and v5 were built from a generated script and diffed |
| **Name the cause the code saw.** Classify gateway errors; don't retry deterministic ones. | Banker test A (BUILD_LOG 2026-10-12) |
| **Trusted URLs ship with the agent.** The org's Lightning and My Domain hosts are `CspTrustedSite` records in source. | Links showed as "URL_Redacted" (BUILD_LOG 2026-10-13, agent run 2) |
| **Cross-client checks need the other clients' names passed in**, and a proper-noun rule. The validator runs no SOQL, so the caller passes the other visible accounts and open deals. A test must prove the check fires end to end, because an empty list silently turns it off. Common words start real company names ("Edge", "United", "Express"). | BUILD_LOG 2026-10-13, step 5c and the sample-accounts row. Scale limit: SCALABILITY_RISKS R9 |
| **One subagent per domain.** A new capability in the same domain is a new action in the existing subagent. When a subagent gains a job, re-read every earlier "always" instruction. | Anti-patterns 1 and 3 below |
| **Repairs need holdout testing.** Code that rewrites model output can introduce errors the model didn't make, and still report "Repaired". | Holdout MTG-0014 (BUILD_LOG 2026-10-12) |

## 3. Test kit

- **`MockLlmGateway`:** queued responses or exceptions; counts calls and the DML count at each call
  (`assertNoDmlBeforeGeneration`). **Tests never call the real LLM.**
- **`SummaryTestData`:** fixtures plus `assertBankerFacing(text, path)`. It rejects "banker", "the agent", "ask the" and
  "tell the user" in code-written text on every reachable path, and every message constant is checked too.
- **Replay plus mutation:** saved real outputs go through the deployed validator in anonymous Apex, with no LLM. First prove
  the replay is meaningful: the live context must be byte-identical (SHA-256) to the resolved prompt's context. Then mutate
  an output in a way that must fail, and check it does (BUILD_LOG 2026-10-13, step 4).
- **Holdouts:** a development set (Halverson, Northwind, Cobalt) and an unseen set (Meridian Health Partners, MTG-0020..0022)
  that no prompt or rule was written against. Don't re-seed the development set: recorded replays depend on its Ids.
- **Agent test spec** (`specs/banker_assistant_tests.yaml`): ID, prompt, expected, and per run the surface, result,
  evidence and finding. **Evidence must post-date the change it verifies:** record the log row Id and time (e.g. the BA-24
  rerun: row a02gK00000SjfOfQAJ at 23:26:44Z, after the 23:23:05Z deploy). Run on the surface bankers use. Agent Builder
  Preview hung where the Lightning panel worked (BA-11).
- **Coverage bar:** at least 90% per class. Cover valid, repaired, fallback, malformed JSON, injection text, empty notes, no
  opportunities, every gateway error category, save failure, invalid reference and no access.

## 4. Per-agent checklist

1. One sentence on what the banker gets, and what must never reach them.
2. Context: a builder method (or reuse one), USER_MODE, source ids, budget and cut order, untrusted blocks. Add a grounding
   invocable class if needed.
3. JSON schema in `docs/`. Prompt v1, then iterate on a fixed test set, recording each version in PROMPT_ITERATIONS
   (version, change, why, before and after on the same record). Freeze the version and set `TEMPLATE_VERSION`.
4. Validator rules, each assigned to block, repair or offline. Reuse `SummaryValidator` and `CitationValidator` helpers
   (money parser, injection patterns, `namesMentioned`, `amountConflictsIn`).
5. Service: `with sharing`, Text inputs validated in code, `MAX_PER_CALL`, all LLM calls before DML, savepoint per record,
   `AiActionSupport` for classification, links, cut and log. Outputs: status, text, review items, banker-facing message,
   link line.
6. Fallback content chosen for its risk: data-only or message-only.
7. Tests with `MockLlmGateway` and `assertBankerFacing`, at least 90% coverage. Replay saved outputs with a mutation check.
8. Security: add the classes to the persona permission set (one per persona), agent access in the same set, Prompt Template
   User for the persona, log access for AI_Ops only, Trusted URLs.
9. Agent: an action in the domain's existing subagent. The Find action sets the guard variable; the AI action has
   available-when, binding and clear. Descriptions carry the agent guidance. Generate the full script and diff the retrieved
   bundle.
10. Agent test spec: happy path, ambiguous, no match, cross-client, injection, off-topic, regenerate or confirm, and a stale
    selection. Run in the Lightning panel and record the log row Ids.
11. Run the holdouts once, at the end. Record known limitations honestly.

## 5. Anti-patterns seen in this build

| Anti-pattern | What happened | Fix | Reference |
| --- | --- | --- | --- |
| **A separate subagent per action** | With Generate in its own subagent, the router picked it, the agent called the built-in `user_select_record`, and the provider returned HTTP 400: "messages with role 'tool' must be a response to a preceeding message with 'tool_calls'." | Both actions moved into one Client Meeting Summary subagent. Meeting Prep Q&A was added to it too (relabelled, API name kept) | BUILD_LOG 2026-10-13 (row recorded on Day 4); AI_TOOLING_LOG same date |
| **LLM-built links** | "Use the link below" with no link (BA-01). A markdown link with another meeting's Id (BA-13). An AI-written snippet had told the agent to compose `[Open MTG-xxxx](Record Link)`. | Links built in Apex, absolute, plain text. Instructions forbid writing or changing a URL | BUILD_LOG 2026-10-13, BA-01 and agent run 2 rows; AI_TOOLING_LOG 2026-10-13 |
| **Instruction conflicts when a subagent gains a job** | v4 instructions 1 ("Always run Find Client Meetings first") and 8 were written for summaries and overrode Q&A instructions 11 to 14. Client questions got a meeting list (BA-17, BA-20, BA-21 failed on routing) | v5: instruction 1 scoped to summaries, 8 rewritten, new 15, Off Topic updated. The v5 reruns passed | BUILD_LOG 2026-10-13, agent v4 run 1 and v5 rows |
| **Agent-directed text in Messages** | "Ask the banker for the client name..." was shown to the banker, because verbatim display makes every output string a UI string | Every Message is banker-facing, enforced by `assertBankerFacing` on every path | BUILD_LOG 2026-10-13, BA-15 rerun row |
| **Trusting the display layer** | BA-19: an instruction branch didn't name Review Items, so a line was dropped. BA-24 (v5 run 1): Generate ran without confirmation, then "Yes" replayed turn 1's result as new, after the guard had correctly made Generate unavailable. | Name every output in every instruction branch (v5 instruction 14). The save time in the Message (8f754b8) makes a replay visible. The record, PDF and log are the system of record | BUILD_LOG 2026-10-13, BA-19 rows and agent v5 run 1; spec BA-24 v5_run_1 and v5_run_2 |
| **Retrying deterministic errors** | A permission error was retried and reported as a validation failure | Error classification; each category gets its own message | BUILD_LOG 2026-10-12, banker test A |
| **Typed inputs for agent-bound values** | `Id` input couldn't bind to a Text variable | Text input, validated in code | BUILD_LOG 2026-10-13, "variable is not found" row |
| **First-word name matching** | Sample accounts made "edge", "united" and "express" count as client names | Full name in any case, or the first word only as a proper noun | BUILD_LOG 2026-10-13, sample-accounts row |
