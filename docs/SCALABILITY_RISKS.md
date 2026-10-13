# Scalability risks

What changes when this reference implementation goes from one Developer Edition org and one tester to an investment bank
with 30+ agents and many bankers. Every number below comes from this build: the `AI_Generation_Log__c` rows (39 rows,
2026-10-12 to 2026-10-13), the ConnectApi spike (BUILD_LOG 2026-10-12, "Unknowns before building ClientSummaryService")
or the code. Nothing here was load-tested. Where a figure is an estimate, or a platform limit still needs checking for
the org's release, it says so.

## 1. What one call costs today (measured)

The template's grounding Apex runs **inside the banker's own transaction, as the banker** (spike: SOQL 6 → 11, CPU +0.5 to
0.7 s per template call, 0 callouts, 0 DML). So every generation spends the caller's governor limits, not a separate
budget.

| | Generate Client Meeting Summary | Answer Client Question |
| --- | --- | --- |
| Log rows (single attempt, real LLM) | 25 | 10 |
| Latency, min / median / max | 3.1 s / 7.2 s / 9.9 s | 2.6 s / 3.4 s / 4.6 s |
| With the one retry (2 rows) | 14.4 s and 14.6 s | none retried so far |
| Context size (chars), max seen | 2,889 (budget 12,000) | 4,878 (budget 12,000) |
| SOQL per attempt | +5 for grounding (spike, measured) plus our own context build | estimate from the code: about 7 for the account context, 2 for other-client names, about 7 more when grounding re-runs the context build. Not measured with `Limits` |
| CPU per attempt | +0.5 to 0.7 s (spike) | not measured |
| LLM generations | 1, or 2 with the retry | 1, or 2 with the retry; 0 on Client mismatch |
| Per-call cap | `MAX_PER_CALL = 3` meetings | `MAX_PER_CALL = 3` questions |

Notes:
- The latency above is the action only. An agent turn adds the planner's own LLM calls before and after the action. That
  time is not in the log and was not measured.
- The context is built twice per attempt: once by our service, which validates against it, and once by the template's
  grounding. That doubles the SOQL and CPU for context. It is the price of validating against exactly what the model saw.
  The drift check confirms the two are the same: 0 of 39 rows logged drift.
- Status mix for Client Summary (29 rows): 6 Valid, 21 Repaired, 2 Fallback. Both fallbacks were the deliberate
  no-permission banker test A (BUILD_LOG 2026-10-12). Repaired is the normal outcome, not a warning: the validator
  replaces next steps with the full clause from the notes and adds amount conflicts.

## 2. Risk register

Likelihood and impact are for a bank-scale rollout (thousands of accounts, hundreds of bankers, 30+ agents on the same
pattern).

| # | Risk | Likelihood | Impact | Mitigation | Owner |
| --- | --- | --- | --- | --- | --- |
| R1 | **Governor limits in the banker's transaction.** Grounding adds SOQL and CPU to our transaction. Worst case at `MAX_PER_CALL = 3` with retries: about 45 SOQL and 4.2 s CPU before PDFs (BUILD_LOG 2026-10-12). | Low at the current caps | High: a limit exception fails the whole call | `MAX_PER_CALL = 3`, with extra requests refused by message, never dropped silently. All LLM calls run before any DML. Measure `Limits` in a full-data sandbox before raising any cap. | Architect |
| R2 | **Latency and action timeouts.** Median 7.2 s for a summary and 14.6 s with a retry, plus planner time per turn. A banker who waits may ask again and trigger a second generation (BA-24 shows the agent may also generate without confirming). | Medium | Medium: slow answers, duplicate generations | One retry only. No retry on PERMISSION or CONFIGURATION errors (BUILD_LOG 2026-10-12, banker test A). The save time in the Message makes a duplicate visible (BUILD_LOG 2026-10-13, BA-24 rerun). Track p95. Confirm the agent action timeout for the org's release; it was not hit or measured here. | Architect, SI |
| R3 | **Concurrent long-running requests.** Every Generate runs longer than 5 s synchronously. Salesforce caps how many such transactions an org can run at once. Whether waiting on ConnectApi counts toward that cap needs verifying (the spike showed it is not a callout). | Medium at 30+ agents | High: org-wide request failures, not just for this feature | Load test with concurrent bankers before rollout. Move bulk work to async (R8). Keep per-call work small. | Architect, Salesforce admin |
| R4 | **Einstein request consumption.** Every attempt is a generation, a retry doubles the cost, and the agent's planner turns consume too. A crash after the call still costs a generation: the spike made 3 calls for 1 result (BUILD_LOG 2026-10-12). | High (it scales linearly with use) | Medium: cost and quota | Retry only invalid output and TRANSIENT errors, once. A client mismatch makes no LLM call. Sum `Attempts__c` from the log per agent and per day, and reconcile with the org's consumption page (Digital Wallet). Put work that can fail before the expensive call. | AI Ops, bank's Salesforce owner |
| R5 | **Context budget growth.** The 12,000-char budget is far from full today (max 4,878), but notes, activity and research grow. Cut order at meeting level: activity, then contacts, then opportunities, then the notes are cut. At account level: activity, contacts, research, then the oldest meetings. CLIENT and OPEN OPPORTUNITIES are never cut. Closed deals are not in context at all (MTG-0017, "Ember"). | Medium | Medium: a relevant fact silently missing from the answer | Every cut is listed under CONTEXT NOTES in the context, so it is visible in the logged prompt. Alert when `Context_Chars__c` passes about 80% of the budget. Any change to what the context contains must re-run the prompt test set and the SHA-256 byte-compare on MTG-0013..0019 (CLAUDE.md). | Architect |
| R6 | **`AI_Generation_Log__c` volume and retention.** One row per generation, and also on Error and Client mismatch. `Raw_Output__c` (up to 32k) holds model output built from client notes, so it is raw client data. There is no purge job today. Illustration only: 500 bankers × 5 generations a day ≈ 2,500 rows a day, about 900,000 a year, roughly 1.8 GB of data storage at the standard 2 KB per record. | High | Medium: storage cost, and client data kept longer than policy allows | OWD Private, AI_Ops-only read, system-mode writes (already built). Add a retention policy, e.g. clear `Raw_Output__c` after N days and keep the metadata (status, attempts, latency, chars) for trends, as a scheduled batch. Agree N with the bank's data governance. | Bank data governance, architect |
| R7 | **File growth.** Every Generate adds a PDF version. When a banker can't add a version to an admin-owned file, a new file is attached instead (BUILD_LOG 2026-10-12, banker test A). | Medium | Low | File retention rule. Optionally make the summary file owned by the meeting owner so versions stack on one file. | Salesforce admin |
| R8 | **No async path.** Everything is synchronous, at 3 records per call. A "prep pack" for a banker's whole week, or a nightly batch, can't run on this path. | High once someone asks for batch | Medium | Queueable chain, one meeting per job, keeping the same order inside each job (all LLM calls before DML, own savepoint, log row). Tell the banker by notification or platform event. `Summary_Status__c` already distinguishes Not Generated, Fallback and Failed. | Architect, SI |
| R9 | **Query selectivity under USER_MODE.** Find Client and Find Client Meetings search with a leading-wildcard `LIKE '%name%'`, which can't use an index. MeetingPrepService loads other clients' names with `Id != :accountId ... ORDER BY Name LIMIT 2000`, a non-selective query run on every question. **Above 2,000 visible accounts (or open deals), names after the cutoff in alphabetical order are silently not checked**, which weakens the cross-client check (BUILD_LOG 2026-10-13, step 5c and the sample-accounts row). | High in a real bank | High for the cross-client check, medium for speed | Invert the check: take the proper nouns from the question and the answer and look only those up (SOSL, or an indexed normalised-name field), instead of loading every name. Until then, log when the 2,000 cap is hit. Use SOSL for Find at scale. Test with the bank's real sharing model (large role hierarchies make USER_MODE queries slower). | Architect |
| R10 | **Monitoring needs structured fields.** `Validation_Errors__c` is long text, so SOQL and reports can't filter or group on it (found while writing this note: "field 'Validation_Errors__c' can not be filtered"). Client mismatch is logged as Status Error with "Error category: CLIENT_MISMATCH" in that text. Not answerable is logged as Valid. | Certain | Medium: blind spots on exactly the numbers in section 3 | Add `Error_Category__c` (picklist: PERMISSION, CONFIGURATION, TRANSIENT, VALIDATION, CLIENT_MISMATCH), `Outcome__c` (the banker-facing status), `Drift__c` (checkbox) and `Repairs__c` (number). Set them in `AiActionSupport.logRow`, so all 30+ agents get them. | Architect |
| R11 | **The agent's LLM is the display layer.** It can trim validated text (BA-19) or replay an earlier result as new (BA-24). Unrelated to load, but every new agent inherits it. | Medium | Medium | The time in the Message, and the record, PDF and log as the system of record (FUNCTIONAL_SPEC_NOTES, "Known limitations (agent v5 run 1)"). Production fix: a custom Lightning Type renderer. | SI, architect |

## 3. What to monitor

From `AI_Generation_Log__c`, per agent (`Capability__c`) and per template version, daily. Items marked (R10) need the
structured fields first.

| Metric | How | Today's baseline | Alert when |
| --- | --- | --- | --- |
| Fallback rate | Status Fallback ÷ rows, split by error category (R10) | 0 real fallbacks; 2 from the permission test | Any rise. A PERMISSION spike means a missing permission set, not model quality |
| Repair rate | Status Repaired ÷ rows | 21 of 27 generated summaries (78%) | A change from baseline, not the absolute number. Repairs are expected (next-step clauses, amount conflicts) |
| Retry rate | rows with `Attempts__c` = 2 | 2 of 37 rows that reached the model (27 summaries, 10 prep answers) | Above about 10%. That is run-to-run variance or a prompt problem: re-run the offline eval |
| Latency p95 | `Latency_Ms__c` | Summary: about 9.3 s single-attempt (24th of 25 rows); Prep: 4.6 s max | p95 above the action timeout minus a margin |
| Context size | `Context_Chars__c` max and p95 | 2,889 / 4,878 of 12,000 | Above about 80% of the budget (R5) |
| Client mismatch count | Error category CLIENT_MISMATCH (R10) | covered by tests, not yet seen live | A rise means bankers ask across clients; review the router and the Find step |
| Context drift | "context drift" note, later `Drift__c` (R10) | 0 of 39 | Any drift: the model saw different facts than were validated. Treat as a defect |
| Display replay | Compare the time in the chat's Message with the log row's `CreatedDate` in agent test runs and in feedback | 1 seen (BA-24, v5 run 1); 0 after 8f754b8 | Any. Re-run the agent test spec on every new agent version |
| Consumption | Sum of `Attempts__c` vs the org's consumption page | not tracked | A budget threshold agreed with the bank |
