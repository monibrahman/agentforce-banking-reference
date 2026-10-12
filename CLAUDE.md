# CLAUDE.md

Context for Claude Code in this repo. Read this, then docs/BUILD\_PLAN.md, before changing anything.

## What this is

A take-home reference implementation for a Salesforce **Partner Technical Architect (Agentforce)** panel interview.
Scenario: an investment bank is live on Agentforce; an SI partner is building 30+ agents for bankers. This repo is the
architect's **reference implementation** that the SI can copy.

* **Capability A (primary): one-click Client Meeting Summary.** After a meeting, the banker clicks a button (or asks the agent) and
gets a structured client summary saved on the record and as a PDF.
* **Capability B (bonus): Meeting Prep Q\&A.** A briefing plus follow-up answers grounded in CRM data and research notes, with source citations.

The panel scores: stack depth, **prompt engineering with before/after iteration**, **architecture trade-offs**, platform judgment,
observability, AI-tooling honesty, and reusable patterns. The repo owner must be able to explain every line. **Explain reasoning in
plain language as you work.**

## Design rule

**The LLM writes. Code gathers the facts and checks the output.**

* Data retrieval is deterministic Apex (never the model "remembering" client facts).
* Prompt templates produce **strict JSON**; Apex validates it; invalid output is retried once with the errors, then replaced by a
deterministic data-only fallback. A banker never sees invented or broken content.
* Every generation is logged to `AI\_Generation\_Log\_\_c`.
* One service class serves both the Quick Action and the agent (no duplicated logic).

## Environment

* Windows, PowerShell. Salesforce CLI authenticated; org alias **`banking`** (a fresh Developer Edition org with Agentforce).
* Never write .apex (or any file sf reads) with PowerShell Set-Content/Out-File; Windows PowerShell 5.1 adds a UTF-8 BOM that Apex rejects. Use the Write tool, or `[IO.File]::WriteAllText(path, text, (New-Object Text.UTF8Encoding $false))`.
* Agent type: **Employee agent** (bankers are internal; the agent runs as the banker and respects their sharing). No agent user needed.
* Objects are created **by hand in Setup** by the repo owner, then retrieved: `sf project retrieve start -m CustomObject:Client\_Meeting\_\_c` etc.
* The prompt template and agent are built **in the UI** (Prompt Builder, Agent Builder), then retrieved:
`sf project retrieve start -m GenAiPromptTemplate` and `-m Bot -m GenAiPlannerBundle` (or `AiAuthoringBundle`, whichever exists; check).

## Data model

`Client\_Meeting\_\_c`

* `Account\_\_c` (Lookup Account, required), `Meeting\_Date\_\_c` (Date), `Attendees\_\_c` (Text 255), `Meeting\_Notes\_\_c` (Long Text 32k)
* `Summary\_\_c` (Rich Text 32k), `Summary\_JSON\_\_c` (Long Text 32k), `Summary\_Status\_\_c` (Picklist: Not Generated, Generated, Generated (Repaired), Fallback, Failed)
* `Summary\_Generated\_At\_\_c` (DateTime), `Summary\_File\_Id\_\_c` (Text 18)

`Research\_Note\_\_c`: `Account\_\_c` (Lookup), `Title\_\_c` (Text 255), `Source\_Type\_\_c` (Picklist: Pitch Deck, Research, Relationship Note), `Body\_\_c` (Long Text 32k), `Published\_Date\_\_c` (Date)

`AI\_Generation\_Log\_\_c`: `Record\_Id\_\_c` (Text 18), `Capability\_\_c` (Picklist: Client Summary, Meeting Prep), `Template\_Name\_\_c`, `Template\_Version\_\_c` (Text),
`Status\_\_c` (Picklist: Valid, Repaired, Fallback, Error), `Attempts\_\_c` (Number), `Validation\_Errors\_\_c` (Long Text), `Latency\_Ms\_\_c` (Number),
`Context\_Chars\_\_c` (Number), `Raw\_Output\_\_c` (Long Text 32k)

## Components to build

**ClientContextBuilder** (Apex)

* `@InvocableMethod(capabilityType='FlexTemplate://Client\_Meeting\_Summary')` grounding method. Input: the Client\_Meeting\_\_c record. Output variable `Prompt` (String).
* Also a plain static method `build(Id meetingId)` returning the same string (used by tests, fallback and MeetingPrepService).
* Queries in **USER\_MODE** (`WITH USER\_MODE` / `AccessLevel.USER\_MODE`): meeting + account (Name, Industry, AnnualRevenue, Type), top 5 contacts,
open opportunities (Name, StageName, Amount, CloseDate, Type), last 90 days of Tasks/Events (max 15), the meeting's notes.
* Tags every fact with a source id `\[S1]`, `\[S2]`... and outputs a compact, labelled block. Enforces a **character budget** (e.g. 12k chars) by truncating
lowest-priority sections first and noting what was truncated.
* Treats notes as **data**: wraps them in clear delimiters and labels them as untrusted user content.

**Client\_Meeting\_Summary** (Prompt Builder Flex template; built by the owner in the UI). Input: `Meeting` (Client\_Meeting\_\_c). Grounding: `{!$Apex:ClientContextBuilder.Prompt}`.
Output must match `docs/summary\_schema.json`.

**ClientSummaryService** (Apex, `@InvocableMethod` label "Generate Client Meeting Summary")

1. Calls the template via `ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate` (input key `Input:Meeting`).
2. Validates: parses JSON, required keys present, types correct, every `source` id cited exists in the context, no amounts that don't appear in the context.
3. On failure: one plain retry of the same template, no validation feedback (see "Retry" below). Still invalid: **fallback** = deterministic summary built from ClientContextBuilder data only, clearly labelled "AI summary unavailable; data-only summary".
4. Renders via SummaryRenderer, saves the fields, attaches a PDF, sets the status, writes `AI\_Generation\_Log\_\_c`.
5. Returns: success, status, summary text (short), file id, message.
* **Validator rules (decided after v4, 2026-10-12; see docs/PROMPT\_ITERATIONS.md "Decision").** Template frozen at version `\_5` (v4 prompt, GPT 5.4).
Raw output varies run to run, so the target is 100% of what reaches the banker, not 100% of raw output:
  * Invalid JSON → retry.
  * Next steps come from the **full clause in the notes**, not from the model's action text (the model may truncate it; v4 GPT 5.4
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
  * Placeholder entries ("None.", "N/A", "-", empty strings) → removed (auto-repair; status Generated (Repaired)).
  * Wording/attribution embellishments → not checked at runtime; offline eval only, on the PROMPT\_ITERATIONS test set.
  * **Retry = plain resample** of the same frozen template (`\_5`), with no validation feedback. The remaining errors are run-to-run
variance, so resampling is enough and keeps the prompt frozen. One retry, then the data-only fallback. Upgrade option ("feedback retry", errors passed back via a second input or a retry template): only
if the offline eval shows a failure that repeats across runs.
* **Template version constant:** the API returns no template version (spike 2026-10-12), so ClientSummaryService logs
`TEMPLATE\_VERSION` (currently `'\_5'`). **Update it whenever the active version of Client\_Meeting\_Summary changes**, and re-run the
offline eval on the PROMPT\_ITERATIONS test set.
* **Context drift:** the response includes the resolved prompt. Always compare its CONTEXT block with `ctx.text` and log any
difference as "context drift" in `Validation\_Errors\_\_c`; validate against `ctx`.
* **Bulk:** `MAX\_PER\_CALL = 3` meetings per invocation (each template call adds +5 SOQL and ~0.5–0.7 s CPU to our transaction);
extra requests get success=false with a clear message, never a silent drop. All LLM calls (incl. retries) for all records happen
before any DML. Each meeting is then saved under its own savepoint (PDF, then meeting update); if the update fails, roll back
to it so no orphan PDF is left, then write the AI\_Generation\_Log\_\_c row.
* The LLM call must sit behind an interface (e.g. `ILlmGateway`) so tests can mock it. **Tests never call the real LLM.**

**SummaryRenderer** (Apex): JSON to clean HTML (sections, tables), then `Summary\_\_c` and a PDF via `Blob.toPdf(html)` saved as a ContentVersion linked to the record.

**MeetingPrepService** (bonus): input Account (and an optional question). Reuses ClientContextBuilder + top Research\_Note\_\_c entries (keyword match on the question,
max 5), all source-tagged. Returns a context block and a source list. A validator rejects answers that cite non-existent `\[S#]` tags.

**Quick Action** on Client\_Meeting\_\_c: "Generate Summary" (screen flow or headless action calling ClientSummaryService).

**Agent: Banker Assistant** (employee agent, built in Agent Builder). Subagents: `client\_summary` (find the meeting by account/date, then call the
Generate Client Meeting Summary action), `meeting\_prep` (bonus), `off\_topic`. Never answers client facts from model memory.

## Quality bar

* Apex: `with sharing`, USER\_MODE queries, bulk-safe invocables, clear `@InvocableVariable` descriptions (the LLM and admins read them).
* Tests: ≥ 90% coverage per class, mock the LLM, cover valid / repaired / fallback / malformed JSON / injection text / empty notes / no opportunities.
* Small focused commits with descriptive messages. Never force-push.

## Logs to maintain (append as you go)

* `docs/BUILD\_LOG.md`: date | symptom | root cause | fix | lesson.
* `docs/AI\_TOOLING\_LOG.md`: date | what the AI tool produced | helped or misled | how it was caught/corrected.
* `docs/PROMPT\_ITERATIONS.md`: version | change | why | before/after output excerpt (same test meeting).

## Final documents (Day 5) outlines

* `docs/Panel\_Overview.pptx` (6–8 slides, high level): Problem \& purpose · Scope · Architecture · Demo screenshots · Methodology (how built, AI tooling) ·
Trade-offs \& platform callouts · Reusable pattern for 30+ agents · Next steps.
* `docs/Functional\_Specification.docx`: Purpose \& scope · Users \& stories · Functional requirements (FR-##) · Architecture \& workflow diagrams (screenshots) ·
Data model · Component definitions (every object, Apex class, prompt template, agent, subagent, action) · Prompt design \& iterations · Error handling \& fallback ·
Security · Observability · Platform constraints · Reusable pattern · Open items.
* `docs/Test\_Protocol.docx` (GxP style): Purpose · Scope · Environment · Approach · Requirements traceability matrix · Test cases
(ID, FR ref, preconditions, steps, expected, actual, pass/fail, evidence screenshot, executed by/date) · Deviations · Summary \& conclusion.
Results source: `docs/test\_results.csv`; screenshots: `docs/screenshots/`.

