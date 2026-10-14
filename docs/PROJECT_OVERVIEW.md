# Project overview: the org, the build, the decisions, the division of work

A short guide to what was built and how. The details are in the documents linked at the end.

## 1. The org and its data

**Org:** a Salesforce Developer Edition org (CLI alias `banking`), with Einstein, Agentforce and Prompt Builder enabled.

### Clients (Accounts)

| Client | Industry | Role in the build | Meetings | Open deals (CRM) |
| --- | --- | --- | --- | --- |
| Halverson Industrial Holdings | Manufacturing | Development set | MTG-0013, MTG-0014 | Project Atlas (USD 1.2bn); 2031 Senior Notes Refinancing (USD 600m) |
| Northwind Maritime Group | Transportation | Development set; injection line, notes-vs-CRM conflict | MTG-0015, MTG-0016, MTG-0019 | Project Keel (USD 850m; notes say ~$1.1bn); Follow-on Offering (USD 300m) |
| Cobalt Ridge Energy | Energy | Development set; no open deals; empty-notes meeting | MTG-0017, MTG-0018 | None (Project Ember is Closed Lost) |
| Meridian Health Partners | Healthcare | Holdout set, unseen until the test run on 2026-10-14 | MTG-0020..0022 | Project Lumen (USD 1.4bn; notes say ~$1.8bn); Term Loan B Refinancing (USD 500m) |
| Aurora Freight Holdings | Transportation | Demo data for live Generate (added after testing) | MTG-0023..0025 | Project Comet (USD 650m; notes say ~$780m); 2032 Senior Notes (USD 400m) |

Each client also has contacts, up to 90 days of tasks and events, and research notes. The org's built-in sample accounts
(Edge Communications, United Oil & Gas, Express Logistics, Grand Hotels, University of Arizona) are still there; they shaped
the cross-client name rule (BUILD_LOG 2026-10-13).

Seed scripts: `seed-data.apex` (the three development clients; don't re-run), `add-conflict-meeting.apex` (MTG-0019),
`seed-data-2.apex` (Meridian), `seed-demo.apex` (Aurora). All but the first are insert-only.

### What we changed in the org

| Area | Change |
| --- | --- |
| Objects (built by hand in Setup) | `Client_Meeting__c`, `Research_Note__c`, `AI_Generation_Log__c` (log OWD set to Private) |
| Standard picklist | Opportunity Type: added M&A, ECM, DCM |
| Apex | 13 classes plus test classes: services, context builder, validators, renderer, agent actions, LLM gateway, shared support |
| Button | Screen Flow `Generate_Client_Meeting_Summary` + quick action on the Client Meeting layout |
| Prompt Builder | `Client_Meeting_Summary` (versions _1 to _5; _5 active, GPT 5.4); `Meeting_Prep_QA` (_1, _2; _2 active, GPT 5.4) |
| Agent | Banker Assistant, an employee agent, versions v1 to v5 (v5 active) |
| Permission sets | `Banker_Summary` (bankers, incl. Run Flows and agent access); `AI_Ops` (log readers). Agent Builder also created `Banker_Assistant_Access` (not needed) |
| Trusted URLs | The org's Lightning and My Domain hosts (otherwise agent links show as `URL_Redacted`) |
| Users | Test Banker: Standard User + `Banker_Summary` + the standard Prompt Template User permission set |

## 2. What we built, and why

**Design rule: the LLM writes; code gathers the facts and checks the output.** A banker never sees invented or broken content.

- **Two capabilities, one pattern.** Client Meeting Summary (a button or the agent) and Meeting Prep Q&A (the agent) both run
  the same five stages: **Context → Template → Validate → Fallback → Log**.
- **Context.** Apex queries in user mode, so the model only sees what the banker can see. Every fact gets a source id, banker
  notes are marked untrusted, and a 12,000-character budget applies.
- **Template.** Prompt Builder returns strict JSON. It is called through an interface, so tests never call the real model.
- **Validate.** Every rule is assigned to one of three tiers: block (one plain retry, then fallback), repair (code fixes it),
  or offline only (wording and attribution, measured on test sets).
- **Fallback.** Option A falls back to a data-only summary; Option B to a message only, because a list of facts would look
  like an answer.
- **Log.** One `AI_Generation_Log__c` row per request, written in system mode so logging never depends on the banker's
  permissions.
- **Agent guard.** A Find action sets a variable only when exactly one record matches. The AI action is available only when
  that variable is set, takes its input from it, and clears it afterwards. The record Id never comes from the LLM.

### Main trade-offs

| Decision | Why | Cost |
| --- | --- | --- |
| Freeze the prompt (v4 on GPT 5.4) and fix the remaining errors in code | Each new rule caused an over-correction elsewhere, and the remaining errors varied run to run | Wording and attribution are measured offline, not guaranteed |
| Plain retry, no feedback | The remaining failures were variance, and the prompt stays frozen | A failure that repeats on the same input (TC-21) can't be retried away |
| Code adds notes-vs-CRM conflicts | The prompt was tuned for precision and missed the real conflict (MTG-0019) | Only amounts are checked, and only within one sentence |
| Extend `ClientContextBuilder` rather than copy it | One budget and tagging implementation | Risk to the frozen _5 input, guarded by a SHA-256 byte-compare |
| One subagent per domain | A separate subagent triggered an HTTP 400 from the platform, and adds routing boundaries | Instructions grow; v4's old "always" rule broke routing until v5 |
| Links built in Apex, plain text | The LLM once wrote a link with the wrong record's Id | Not clickable rich output; the production fix is a Lightning Type renderer |
| Text inputs, validated in code | Agent Builder only binds variables to matching types | More validation code |
| Synchronous, 3 records per call | Grounding spends the banker's own governor limits | No batch path yet |

**What testing showed** (pre-registered protocol, 2026-10-14): 20 Pass, 4 Fail, 2 Not run.
- Two failures were the agent's display layer (one dropped a message, one replayed an old result).
- The holdout found a pair of initials problems:
  - "RK" was resolved to Rachel Kim in Q&A and to Ryan Kowalski in a summary. Both passed validation.
  - "P. Raman" was correctly expanded to Priya Raman but over-blocked, and failed safe.
- The fixes are proposed and not applied.

## 3. Who decided what

### Where I overrode or corrected the AI

| What the AI did | What happened |
| --- | --- |
| Treated `capabilityType` as required for grounding and kept retrying the deploy | I checked Prompt Builder: grounding works without it. Kept unbound (loose coupling) |
| Wrote a script with PowerShell `Set-Content` (adds a BOM Apex rejects) | I diagnosed it; the rule went into CLAUDE.md |
| Planned to retrieve the wrong metadata for Opportunity Type values | Caught in plan review (it's a StandardValueSet) |
| Predicted a "no access to this flow" error for bankers | My banker test showed the button was simply hidden; the fix was Run Flows |
| Wrote an agent snippet that formatted links as markdown | Contributed to the wrong-record link (BA-13); links now come only from code |
| Said the name check exempted only the selected client, implying others were checked | My question exposed that other clients weren't checked; the check was then built and proven end to end |
| Proposed a `meetingId` input on the Q&A action | Rejected: an LLM-filled Id would bypass the account guard |
| Recorded first-pass results before transcripts arrived; read "pasted twice" as "ran twice" | I supplied the transcripts and corrected TC-20 |

The AI also logged its own mistakes (shadowed variable names, the YAML commit that went in before validation). The full list
is in `AI_TOOLING_LOG.md` (21 entries).

### Decisions I made myself

- Adopt GPT 5.4 and freeze the prompt; aim for "100% of what reaches the banker"; use a plain retry rather than a feedback retry.
- Every Message is written to the banker; links come only from code; validated output is shown verbatim.
- The evidence rule: evidence must post-date the change it verifies (log row Id and time).
- Keep a holdout client unseen; pre-register the test protocol before any run.
- Option B design: no meetingId input; the client-mismatch rule; numbers in `missing[]` blocked; reuse the Option A conflict check;
  keep the subagent's API name; match "Project <Word>" code names only.
- Put the save time in Generate's Message (makes a replayed result visible) instead of changing the agent.
- Test calls: TC-04 judged with a criterion-wording deviation; duplicate output treated as cosmetic; TC-22 step 4 recorded as a
  deviation; TC-23 and TC-25 not run.

### Where the AI pushed back on me (and I agreed)

- Not to edit pre-registered criteria (REQ-19, TC-04): record a deviation instead.
- Not to remove TC-23 from the protocol, and not to use a reason that wasn't accurate.
- The holdout wording: TC-19's attribution did reach a banker, so "neither put a wrong fact in front of a banker" was wrong.
- My first diagnosis of BA-19 (the flag depends on the model) was wrong; the logged output showed the agent dropped a line.

## 4. Division of work and token efficiency

No token counts were recorded, so this section describes the approach, not measurements.

| Done by me (UI, no AI tokens) | Done by Claude Code |
| --- | --- |
| Objects in Setup, permission set assignments, users | Apex, tests, deploys, retrieves and diffs |
| Prompt Builder: each prompt version, previews, activation | Analysis of each prompt version, claim by claim, against org data |
| Agent Builder: pasting generated scripts, activating versions | Generating the full agent script; diffing the deployed bundle |
| Running every agent and button test; pasting transcripts | Evidence queries, test records, logs and documents |
| Reviewing every plan and report before the next step | Scripts that rebuild the documents |

What kept the AI work efficient:
- **Plan first, then build:** each step was planned and reviewed before any code was written, so little was thrown away.
- **Stages with a review gate:** I approved each stage before the next one started.
- **Evidence by query, not screenshots:** log row Ids and field values are cheaper to collect and check than images.
- **Generated, not hand-pasted, agent scripts:** after a guard line went missing in v2, the full script was generated and
  diffed, which removed rework.
- **Reusable scripts:** replay, mutation and document builders are rerun instead of being rewritten.
- **Manual UI steps stayed manual:** clicking through Setup, Prompt Builder and Agent Builder is faster by hand than describing
  it to an AI.

Where tokens were wasted:
- Shell quoting problems (backslashes in heredocs) caused repeated edits.
- One search through a 43 MB session transcript was too slow and had to be stopped.
- Missing attachments meant some results were recorded twice.

## Further reading

`README.md` (architecture diagram, deploy steps) · `docs/Functional_Specification.docx` · `docs/Test_Protocol.docx` ·
`docs/Panel_Overview.pptx` · `docs/BUILD_LOG.md` · `docs/AI_TOOLING_LOG.md` · `docs/PROMPT_ITERATIONS.md` ·
`docs/SCALABILITY_RISKS.md` · `docs/REUSABLE_PATTERN.md`
