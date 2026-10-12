# CLAUDE.md

Context for Claude Code in this repo. Read this, then the plan for the current phase, before changing anything.

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
- Prompt templates produce **strict JSON**; Apex validates it; invalid output is retried once with the errors, then replaced by a
  deterministic data-only fallback. A banker never sees invented or broken content.
- Every generation is logged to `AI_Generation_Log__c`.
- One service class serves both the Quick Action and the agent (no duplicated logic).

## Environment

- Windows, PowerShell. Salesforce CLI authenticated; org alias **`banking`** (a fresh Developer Edition org with Agentforce).
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
- `@InvocableMethod(capabilityType='FlexTemplate://Client_Meeting_Summary')` grounding method. Input: the Client_Meeting__c record. Output variable `Prompt` (String).
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
3. On failure: one retry with the validation errors appended (pass via a second template input or a retry variant). Still invalid: **fallback** = deterministic summary built from ClientContextBuilder data only, clearly labelled "AI summary unavailable; data-only summary".
4. Renders via SummaryRenderer, saves the fields, attaches a PDF, sets the status, writes `AI_Generation_Log__c`.
5. Returns: success, status, summary text (short), file id, message.
- The LLM call must sit behind an interface (e.g. `ILlmGateway`) so tests can mock it. **Tests never call the real LLM.**

**SummaryRenderer** (Apex): JSON to clean HTML (sections, tables), then `Summary__c` and a PDF via `Blob.toPdf(html)` saved as a ContentVersion linked to the record.

**MeetingPrepService** (bonus): input Account (and an optional question). Reuses ClientContextBuilder + top Research_Note__c entries (keyword match on the question,
max 5), all source-tagged. Returns a context block and a source list. A validator rejects answers that cite non-existent `[S#]` tags.

**Quick Action** on Client_Meeting__c: "Generate Summary" (screen flow or headless action calling ClientSummaryService).

**Agent: Banker Assistant** (employee agent, built in Agent Builder). Subagents: `client_summary` (find the meeting by account/date, then call the
Generate Client Meeting Summary action), `meeting_prep` (bonus), `off_topic`. Never answers client facts from model memory.

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
