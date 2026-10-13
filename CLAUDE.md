# CLAUDE.md

Context for Claude Code in this repo. Read this, then docs/BUILD_PLAN.md, before changing anything.

## What this is

A take-home reference implementation for a Salesforce **Partner Technical Architect (Agentforce)** panel interview.
Scenario: an investment bank is live on Agentforce; an SI partner is building 30+ agents for bankers. This repo is the
architect's **reference implementation** that the SI can copy.

- **Capability A (primary): one-click Client Meeting Summary.** After a meeting, the banker clicks a button (or asks the agent) and
  gets a structured client summary saved on the record and as a PDF.
- **Capability B (bonus): Meeting Prep Q&A.** A briefing plus follow-up answers grounded in CRM data and research notes, with source citations.

The panel scores: stack depth, **prompt engineering with before/after iteration**, **architecture trade-offs**, platform judgment,
observability, AI-tooling honesty, and reusable patterns. The repo owner must be able to explain every line. **Explain reasoning in
plain language as you work.**

## Design rule

**The LLM writes. Code gathers the facts and checks the output.**

- Data retrieval is deterministic Apex (never the model "remembering" client facts).
- Prompt templates produce **strict JSON**; Apex validates it; invalid output is retried once (plain resample of the same frozen
  template, no feedback), then replaced by a deterministic data-only fallback. A banker never sees invented or broken content.
- Every generation is logged to `AI_Generation_Log__c`.
- One service class serves both the Quick Action and the agent (no duplicated logic).

## Environment

- Windows, PowerShell. Salesforce CLI authenticated; org alias **`banking`** (a fresh Developer Edition org with Agentforce).
- Never write .apex (or any file sf reads) with PowerShell Set-Content/Out-File; Windows PowerShell 5.1 adds a UTF-8 BOM that Apex rejects. Use the Write tool, or `[IO.File]::WriteAllText(path, text, (New-Object Text.UTF8Encoding $false))`.
- Agent type: **Employee agent** (bankers are internal; the agent runs as the banker and respects their sharing). No agent user needed.
- Objects are created **by hand in Setup** by the repo owner, then retrieved: `sf project retrieve start -m CustomObject:Client_Meeting__c` etc.
- The prompt template and agent are built **in the UI** (Prompt Builder, Agent Builder), then retrieved:
  `sf project retrieve start -m GenAiPromptTemplate` and `-m Bot -m GenAiPlannerBundle` (or `AiAuthoringBundle`, whichever exists; check).

## Data model

`Client_Meeting__c`

- `Account__c` (Lookup Account, required), `Meeting_Date__c` (Date), `Attendees__c` (Text 255), `Meeting_Notes__c` (Long Text 32k)
- `Summary__c` (Rich Text 32k), `Summary_JSON__c` (Long Text 32k), `Summary_Status__c` (Picklist: Not Generated, Generated, Generated (Repaired), Fallback, Failed)
- `Summary_Generated_At__c` (DateTime), `Summary_File_Id__c` (Text 18)

`Research_Note__c`: `Account__c` (Lookup), `Title__c` (Text 255), `Source_Type__c` (Picklist: Pitch Deck, Research, Relationship Note), `Body__c` (Long Text 32k), `Published_Date__c` (Date)

`AI_Generation_Log__c`: `Record_Id__c` (Text 18), `Capability__c` (Picklist: Client Summary, Meeting Prep), `Template_Name__c`, `Template_Version__c` (Text),
`Status__c` (Picklist: Valid, Repaired, Fallback, Error), `Attempts__c` (Number), `Validation_Errors__c` (Long Text), `Latency_Ms__c` (Number),
`Context_Chars__c` (Number), `Raw_Output__c` (Long Text 32k)

## Components to build

**ClientContextBuilder** (Apex)

- `@InvocableMethod` grounding method, deliberately **unbound** (no `capabilityType`): loose coupling, so the same class can
  ground other templates (see BUILD_LOG, capabilityType row). It appears in Prompt Builder under Insert Resource → Apex as
  "Client Meeting Context". Input: the Client_Meeting__c record. Output variable `Prompt` (String).
- Also a plain static method `build(Id meetingId)` returning the same string (used by tests, fallback and MeetingPrepService).
- Queries in **USER_MODE** (`WITH USER_MODE` / `AccessLevel.USER_MODE`): meeting + account (Name, Industry, AnnualRevenue, Type), top 5 contacts,
  open opportunities (Name, StageName, Amount, CloseDate, Type), last 90 days of Tasks/Events (max 15), the meeting's notes.
- Tags every fact with a source id `[S1]`, `[S2]`... and outputs a compact, labelled block. Enforces a **character budget** (e.g. 12k chars) by truncating
  lowest-priority sections first and noting what was truncated.
- Treats notes as **data**: wraps them in clear delimiters and labels them as untrusted user content.

**Client_Meeting_Summary** (Prompt Builder Flex template; built by the owner in the UI). Input: `Meeting` (Client_Meeting__c). Grounding: `{!$Apex:ClientContextBuilder.Prompt}`.
Output must match `docs/summary_schema.json`.

**ClientSummaryService** (Apex, `@InvocableMethod` label "Generate Client Meeting Summary")

1. Calls the template via `ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate` (input key `Input:Meeting`).
2. Validates: parses JSON, required keys present, types correct, every `source` id cited exists in the context, no amounts that don't appear in the context.
3. On failure: one plain retry of the same template, no validation feedback (see "Retry" below). Only invalid output and
   TRANSIENT gateway errors are retried; PERMISSION (e.g. no Prompt Template User) and CONFIGURATION (template missing/inactive)
   errors are not. Every fallback message names the cause the code saw; only real validation failures say "did not pass the checks". Still invalid: **fallback** = deterministic summary built from ClientContextBuilder data only, clearly labelled "AI summary unavailable; data-only summary".
4. Renders via SummaryRenderer, saves the fields, attaches a PDF, sets the status, writes `AI_Generation_Log__c`.
5. Returns: success, status, summary text (short), file id, message.
- **Validator rules (decided after v4, 2026-10-12; see docs/PROMPT_ITERATIONS.md "Decision").** Template frozen at version `_5` (v4 prompt, GPT 5.4).
  Raw output varies run to run, so the target is 100% of what reaches the banker, not 100% of raw output:
  - Invalid JSON → retry.
  - Next steps come from the **full clause in the notes**, not from the model's action text (the model may truncate it; v4 GPT 5.4
    returned "send buyer list" for "send buyer list (TB)"). For each `nextSteps` item:
    1. Locate the model's `action` text in the meeting notes (exact substring). Not found, or found more than once → retry.
    2. Extend it in both directions to the clause boundaries. Comma, semicolon and newline are boundaries both ways (or start/end
       of notes); a colon is a start boundary only, so list labels ("next:", "next steps:") drop off without a label list. A colon
       between two digits is not a boundary ("9:30" doesn't cut a clause). A spaced dash ("ratings - ...") is a start boundary
       like the colon. A period followed by whitespace **is** a boundary both ways, except after a single capital letter
       ("S. Mendes"), a known abbreviation (approx., e.g., i.e., vs., Mr., Mrs., Ms., Dr., Inc., Corp., Co., No., wk.) or
       between digits. Trim whitespace and a trailing period. An objectless "<owner> to <verb>" clause ("PR to set up") is
       extended back across one comma in the same sentence ("pre-sounding w/ both agencies needed, PR to set up"); the owner
       still comes from the "X to" part. (Holdout MTG-0014, 2026-10-12: repairs need holdout testing.)
    3. Apply the owner rules to that clause; the model's `owner` is ignored: trailing "(XX)" → "Unassigned"; "we ..." / "our
       team ..." → "Deal team"; "X to verb" → X **only if** X is a team word from the constant list (legal, tax, compliance, credit,
       ECM, DCM, M&A), or an attendee/contact by full name or unique initials (no unique match → "Unassigned"); anything else →
       "Unassigned" (so "write to the CFO" is Unassigned, not "write").
    4. Replace `action` with the full clause.
    5. A clause that overlaps an `ignoredInstructions` quote or matches the injection patterns → retry, then fallback. Never a
       silent drop: an injected sentence must not reach the banker as a next step, and dropping it quietly would hide that it happened.
  - Placeholder entries ("None.", "N/A", "-", empty strings) → removed (auto-repair; status Generated (Repaired)).
  - **Amount conflicts are added by code** (the prompt's "when in doubt, leave conflicts empty" misses real ones; MTG-0019,
    2026-10-12). For each notes sentence (not an injection sentence) that names an open opportunity by a distinctive word (not
    Project/Acquisition/Sale/Offering/Refinancing/of/the or the account name) and states a parsed amount: if no amount in it is
    within 10% of the opportunity's CRM amount (amounts matching another context figure don't count), add a conflict as a repair:
    "Notes state <as written> for <opp>; CRM amount is <USD>. CRM may be out of date — review the opportunity.", sources notes id +
    opportunity id. One per deal; none if the model already reported a conflict citing both.
  - Wording/attribution embellishments → not checked at runtime; offline eval only, on the PROMPT_ITERATIONS test set.
  - **Retry = plain resample** of the same frozen template (`_5`), with no validation feedback. The remaining errors are run-to-run
    variance, so resampling is enough and keeps the prompt frozen. One retry, then the data-only fallback. Upgrade option ("feedback retry", errors passed back via a second input or a retry template): only
    if the offline eval shows a failure that repeats across runs.
- **Template version constant:** the API returns no template version (spike 2026-10-12), so ClientSummaryService logs
  `TEMPLATE_VERSION` (currently `'_5'`). **Update it whenever the active version of Client_Meeting_Summary changes**, and re-run the
  offline eval on the PROMPT_ITERATIONS test set.
- **Context drift:** the response includes the resolved prompt. Always compare its CONTEXT block with `ctx.text` and log any
  difference as "context drift" in `Validation_Errors__c`; validate against `ctx`.
- **Bulk:** `MAX_PER_CALL = 3` meetings per invocation (each template call adds +5 SOQL and ~0.5–0.7 s CPU to our transaction);
  extra requests get success=false with a clear message, never a silent drop. All LLM calls (incl. retries) for all records happen
  before any DML. Each meeting is then saved under its own savepoint (PDF, then meeting update); if the update fails, roll back
  to it so no orphan PDF is left, then write the AI_Generation_Log__c row.
- The LLM call must sit behind an interface (e.g. `ILlmGateway`) so tests can mock it. **Tests never call the real LLM.**

**SummaryRenderer** (Apex): JSON to clean HTML (sections, tables), then `Summary__c` and a PDF via `Blob.toPdf(html)` saved as a ContentVersion linked to the record.
All model and banker text is HTML-escaped. Sections include:
- "Open deals for this client (from CRM)": the deals table. It lists every open deal in the context, not only the ones discussed, so
  the heading says so.
- "Where the notes and CRM disagree": the conflicts (model-reported, plus amount conflicts added by the validator).
- "For review: text in the notes that looked like an instruction to the AI": ignoredInstructions, neutral wording (not a verdict).
- "Sources": one line per cited S# ("S5 — Opportunity: Project Keel - ..."), linked to the record (`/lightning/r/<Id>/view`)
  in `Summary__c`; plain text in the PDF (links stripped).
- Fallback: "AI summary unavailable; data-only summary" banner, the context's facts and the notes verbatim; no LLM text.

**MeetingPrepService** (bonus): input Account (and an optional question). Reuses ClientContextBuilder + top Research_Note__c entries (keyword match on the question,
max 5), all source-tagged. Returns a context block and a source list. A validator rejects answers that cite non-existent `[S#]` tags.

**Quick Action** on Client_Meeting__c: the Screen Flow `Generate_Client_Meeting_Summary` (calls the "Generate Client Meeting
Summary" action with the record Id, shows status, message and summary; fault path to an error screen) behind the quick action
`Client_Meeting__c.Generate_Summary`, placed on the Client Meeting Layout.

**FindClientMeetingsAction** (Apex, `@InvocableMethod` label "Find Client Meetings"; `with sharing`, USER_MODE): lets the agent
turn "my Northwind meeting last week" into a meeting Id. Optional inputs, at least one: `accountName` (partial, any case),
`dateFrom` / `dateTo` (YYYY-MM-DD, inclusive; the same date in both for one day; either alone is open-ended), `meetingName`
(e.g. MTG-0019, exact, any case). Returns up to 5 matches, newest first, plus `totalMatches`. Each match has the Id, name,
client, date, attendees, summary status and generated-at time, and a record link. It also returns `matchesText` and a
`message`. **Metadata only: never the notes or summary text**, so the agent can't answer from raw notes. No inputs or no
access → a clear message, never an exception. Descriptions tell the planner never to show record Ids to the banker.

**Agent: Banker Assistant** (employee agent, built in Agent Builder). Subagents: `client_summary` (find the meeting by account/date, then call the
Generate Client Meeting Summary action), `meeting_prep` (bonus), `off_topic`. Never answers client facts from model memory.

## Security

- **Banker access:** permission set `Banker_Summary` (Client_Meeting__c read/create/edit + fields, read on the grounding data,
  Apex `ClientSummaryService` + `ClientContextBuilder` + `FindClientMeetingsAction`, the flow, and Run Flows). **Minimum banker access = `Banker_Summary` +
  the standard Prompt Template User permission set** (banker tests A/B, 2026-10-12). Without Prompt Template User the banker
  gets a data-only summary and a message to ask the admin.
- **`AI_Generation_Log__c`** holds raw client data: OWD **Private**, read only through the `AI_Ops` permission set (read + View
  All). Bankers get no access, even to rows their clicks created.
- **The agent's LLM must not rewrite validated output.** Generate Client Meeting Summary's `summaryText` and `message` are
  shown to the banker exactly as returned; the action descriptions say so ("do not paraphrase, shorten or add facts").
- Logs are written in **system mode**, so logging never depends on the banker's permissions. Meeting reads and writes are
  in **user mode**, so the banker's sharing and field access apply, including inside the template's grounding call.

## Quality bar

- Apex: `with sharing`, USER_MODE queries, bulk-safe invocables, clear `@InvocableVariable` descriptions (the LLM and admins read them).
- Tests: ≥ 90% coverage per class, mock the LLM, cover valid / repaired / fallback / malformed JSON / injection text / empty notes / no opportunities.
- Small focused commits with descriptive messages. Never force-push.

## Logs to maintain (append as you go)

- `docs/BUILD_LOG.md`: date | symptom | root cause | fix | lesson.
- `docs/AI_TOOLING_LOG.md`: date | what the AI tool produced | helped or misled | how it was caught/corrected.
- `docs/PROMPT_ITERATIONS.md`: version | change | why | before/after output excerpt (same test meeting).

## Final documents (Day 5) outlines

- `docs/Panel_Overview.pptx` (6–8 slides, high level): Problem & purpose · Scope · Architecture · Demo screenshots · Methodology (how built, AI tooling) ·
  Trade-offs & platform callouts · Reusable pattern for 30+ agents · Next steps.
- `docs/Functional_Specification.docx`: Purpose & scope · Users & stories · Functional requirements (FR-##) · Architecture & workflow diagrams (screenshots) ·
  Data model · Component definitions (every object, Apex class, prompt template, agent, subagent, action) · Prompt design & iterations · Error handling & fallback ·
  Security · Observability · Platform constraints · Reusable pattern · Open items.
- `docs/Test_Protocol.docx` (GxP style): Purpose · Scope · Environment · Approach · Requirements traceability matrix · Test cases
  (ID, FR ref, preconditions, steps, expected, actual, pass/fail, evidence screenshot, executed by/date) · Deviations · Summary & conclusion.
  Results source: `docs/test_results.csv`; screenshots: `docs/screenshots/`.

