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
- **A failed save can leave the PDF attached.** The file is attached before the meeting update (the update needs the file id);
  if the update then fails, the banker sees Failed and the log says Error, but the PDF remains on the record. Open item.
- Meeting fields (`Summary__c`, `Summary_JSON__c`, status, file) are written in user mode: a banker without edit access gets a
  Failed result, never a silent write.

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

## Observability
- The response includes the resolved prompt. Its CONTEXT block is compared with the context ClientSummaryService validated
  against; any difference is logged as "context drift" in `Validation_Errors__c`. Spike: identical (2,494 chars).
- What runtime validation can't catch: wording and attribution errors (e.g. "asked for comfort letters"). They are measured
  offline on the PROMPT_ITERATIONS test set, not guaranteed at runtime.
