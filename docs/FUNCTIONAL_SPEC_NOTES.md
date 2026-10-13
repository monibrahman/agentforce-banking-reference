# Functional Specification notes

Facts and decisions collected while building, for `docs/Functional_Specification.docx` (Day 5). Each note names the spec
section it belongs to and where the evidence is.

## Security
- **Apex grounding runs as the calling user, inside our transaction.** The Flex template runs `ClientContextBuilder` in the same
  Apex transaction as the caller (ClientSummaryService or the agent action), as the same user. Its `WITH USER_MODE` queries
  therefore apply the banker's sharing and field access, so the model only gets what the banker can see. Evidence: spike
  2026-10-12 (BUILD_LOG), SOQL count rose by 5 during the template call.
- **AI_Generation_Log__c holds raw client data** (raw model output, validation errors that quote it). Org-wide default Private;
  read access only through the `AI_Ops` permission set (admins / AI operations; read + View All, no edit). Bankers have no access. ClientSummaryService
  writes the log in system mode so logging doesn't depend on the banker's permissions. Decision: owner, 2026-10-12.
  Note: the banker who triggers a summary *owns* the log row, but has no object permission on AI_Generation_Log__c, so
  ownership under Private sharing does not expose it. Do not grant bankers read on this object.
- **Model and banker text is HTML-escaped** before it reaches `Summary__c` or the PDF, so a note or a model output containing
  markup can't inject script into the record page.
- ~~**A failed save can leave the PDF attached.**~~ **Closed 2026-10-12.** The file is attached before the meeting update (the
  update needs the file id). Each meeting is now saved under its own Database savepoint: if the update fails, the PDF is rolled
  back with it, the banker sees Failed, and the AI_Generation_Log__c row (status Error) is written after the rollback. Other
  meetings in the same call are unaffected. Tests: `saveFailureIsReportedAndLogged`, `failedSaveRollsBackOnlyThatMeeting`.
- **Banker access is one permission set, `Banker_Summary`** (metadata in source): read/create/edit on Client_Meeting__c and its
  fields; read on Account, Contact, Opportunity and the fields the context uses; Apex access to `ClientSummaryService` (the action)
  and `ClientContextBuilder` (the template's grounding runs as the banker); access to the `Generate_Client_Meeting_Summary` flow,
  plus the **Run Flows** user permission. The flow doesn't restrict access, so the per-flow grant alone is not enough; without
  Run Flows the button is hidden (banker test, 2026-10-12; BUILD_LOG).
- **Minimum banker permissions: `Banker_Summary` + the standard `Prompt Template User` permission set.** Banker test A
  (2026-10-12): with Banker_Summary only, the template call fails with "Insufficient Privileges: This feature is not currently
  enabled for this user." The banker still gets a data-only summary (status Fallback) and the message: "AI summaries aren't
  enabled for your user (missing the Prompt Template User permission). A data-only summary was saved. Ask your Salesforce admin
  for access." Logged as error category PERMISSION, Attempts 1 (not retried); the real exception is `System.NoAccessException`.
  **Confirmed by test B:** with both permission sets the banker gets a proper summary (Valid, 1 attempt) and cannot see
  AI Generation Logs. Evidence: BUILD_LOG banker-test rows; screenshots `banker_no_prompt_permission_after_fix.png`,
  `banker_with_prompt_permission.png`.
- **Summary PDFs are owned by whoever generated them.** A banker can't add a version to a file another user created, so the
  service attaches a new file and points `Summary_File_Id__c` at it; the older file stays on the record (test A). Option if
  this matters: a single owner for summary files (e.g. created by an integration user), at the cost of the files no longer
  being created as the banker.
  No access to AI_Generation_Log__c. Other classes (validator, renderer, gateway) need no class access: they are called from
  Apex, not by the user. Tasks/Events come from the profile (no activity object permissions exist in permission sets). Bankers
  also need the standard **Prompt Template User** permission set to generate; the owner's end-to-end test records what a
  banker sees without it.
- Meeting fields (`Summary__c`, `Summary_JSON__c`, status, file) are written in user mode: a banker without edit access gets a
  Failed result, never a silent write.

- **The agent's LLM is not allowed to rewrite validated output** (owner decision, 2026-10-13). The summary text and
  message from Generate Client Meeting Summary have passed the validator, or are the deterministic fallback. If the agent
  paraphrased them, it could reintroduce exactly what validation removed: invented facts, a wrong owner, a dropped conflict.
  The action and output descriptions tell the planner to show them exactly as returned ("do not paraphrase, shorten or add
  facts; this text has been validated") and to answer questions about the meeting only from that output. This is an
  instruction to the planner, not an enforced control: the end-to-end agent tests (Day 3) must check it.
- **Links are facts, so they come only from code** (agent run 2, 2026-10-13). The agent's own reply once invented a link
  that put MTG-0014's Id under MTG-0019's name, mixing records from earlier in the chat. Links are therefore built in Apex for
  the exact record (`ClientSummaryService.openLine`: "Open MTG-xxxx: https://...") and only shown from action outputs. The
  descriptions and the subagent instructions forbid writing, rebuilding or changing a URL. That instruction can't be
  enforced, so run 3 must check it.
- **Trusted URLs bound the domain, not the record.** Agentforce redacts URLs whose domain isn't a Trusted URL
  (`URL_Redacted`). The org's Lightning and My Domain hosts are trusted (`CspTrustedSite` Banking_Org_Lightning,
  Banking_Org_MyDomain, in source). This stops links to outside domains, but any link to *this* org passes, including
  a wrong record. Record-level correctness comes from building links in code, not from the Trusted URL list.
- **Agent access is in Banker_Summary** (`agentAccesses` Banker_Assistant). Minimum banker access stays **Banker_Summary +
  Prompt Template User**. Agent Builder also created `Banker_Assistant_Access`, which isn't needed for bankers.
- **Find Client Meetings returns metadata only** (name, client, date, attendees, summary status and time, link), never
  notes or summary text. The agent therefore has no raw notes to answer from, and can only reach meeting content through
  the validated summary. Queries run in user mode, so a banker only finds meetings they can see. Descriptions tell the
  planner never to show record Ids; meetings are referred to by name, client and date.

## Platform constraints
- **Each template call costs our transaction +5 SOQL and ~0.5–0.7 s CPU** (the grounding Apex), on top of the ~5 SOQL to build
  the context for validation. ConnectApi generation does not count as a callout (Limits.getCallouts stayed 0). Latency 3–8 s per
  call (owner's timings; spike 6.4 s).
- **Bulk cap `MAX_PER_CALL = 3`** meetings per invocation. Worst case is 2 calls per meeting (first try + one retry): about 48 s,
  ~45 SOQL and ~4.2 s CPU before PDF rendering. Five meetings would reach ~7 s of the 10 s CPU limit. Requests beyond the cap
  return a clear "too many" message; none are silently dropped.
- **The API returns no template version.** The version that ran is logged from a constant, which must be updated whenever the
  active template version changes (CLAUDE.md rule).
- **ConnectApi output objects are read-only outside tests** (the spike crashed on this).

## Error handling
- **Gateway errors are classified before retrying** (`ClientSummaryService.classify`). PERMISSION (user can't run the
  template) and CONFIGURATION (template missing or inactive) give the same answer every time, so they are not retried.
  TRANSIENT (timeout, service unavailable, anything unrecognised) gets the one plain retry. Invalid output is VALIDATION and
  also gets the retry. Every path still saves the data-only summary (status Fallback), with a message naming the cause; only
  VALIDATION says "did not pass the checks". The category is the first line of `Validation_Errors__c`
  ("Error category: PERMISSION"); a dedicated `Error_Category__c` field would make it reportable (owner Setup task, if wanted).
- The PERMISSION text is the real one from test A. The CONFIGURATION texts are not yet confirmed against the real API; until
  they are, an unrecognised configuration error is retried once as TRANSIENT and gets the generic "didn't respond" message.

## Known limitations and next steps
- **Closed deals are not in the context.** `ClientContextBuilder` includes open opportunities only. Holdout MTG-0017's notes
  say "Ember still a sore point - dont raise"; CRM has **Project Ember - Sale of Midstream Assets** (M&A, Closed Lost, USD 900,000,000,
  closed 2026-05-14), but the model never
  saw it and could only list "the context does not provide details on what Ember refers to" as a data gap. Proposed
  enhancement: a "RECENTLY CLOSED DEALS (last 12 months)" context section (name, type, stage Won/Lost, amount, close date),
  lower priority than open deals in the character budget. It changes what the model sees, so it **requires rerunning the
  prompt test set and holdouts** (and the validator's amount list grows with it).
- **The deals table lists all open deals, not the ones discussed.** Holdout MTG-0015 listed Project Keel, which the notes
  never mention; v4 MTG-0013 listed the Senior Notes Refi alongside Atlas. The renderer's heading is now "Open deals for
  this client (from CRM)", which is what the table actually shows. Filtering to deals the notes mention would be a prompt or
  validator change, with a rerun of the test set.

- **Agent output is plain text.** Action outputs shown in the conversation render as plain text in both the Preview and
  the Lightning panel, so markdown links aren't clickable. The link is a bare https URL on its own line, which the panel
  can link. **Production path for clickable, rich output: a custom Lightning Type with its own renderer** (an LWC) for
  the summary result: sections, a link button and review items styled, instead of plain-text outputs.
- **Known limitation (cosmetic): agent outputs run together on one line** in the Lightning panel (run 3). Content and
  links are correct; layout is not. Same production path: a custom Lightning Type renderer for the summary result.
- **Guard in the agent (version 2):** Generate's Meeting Id is bound to `selected_meeting_id`, which every Find sets and
  every Generate clears. The intended `available when` condition is not in the deployed version (bundle diff,
  2026-10-13). The backstop is in code: an empty Meeting Id fails before any generation.
- **Agent Builder Preview isn't the production surface.** BA-11's "summarize it" hung 4 times in Preview with no trace
  entry, but worked in the Lightning panel. Agent tests record the surface per result, and the Lightning panel counts.

## Observability
- The response includes the resolved prompt. Its CONTEXT block is compared with the context ClientSummaryService validated
  against; any difference is logged as "context drift" in `Validation_Errors__c`. Spike: identical (2,494 chars).
- What runtime validation can't catch: wording and attribution errors (e.g. "asked for comfort letters"). They are measured
  offline on the PROMPT_ITERATIONS test set, not guaranteed at runtime.
