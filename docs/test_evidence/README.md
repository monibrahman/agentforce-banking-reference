# Test evidence

Evidence for `docs/TEST_PROTOCOL.md`. Results are in `docs/test_results.csv`.

- `TC-xx.md`: one file per test case. It holds the transcript or screen text as pasted by the executor, the query output
  (log row Id and CreatedDate, record field values, ContentVersion Id and CreatedDate) and the execution window.
- `TC-03_expected/`: the expected outputs for TC-03, committed with the protocol before execution:
  - `ctx_hashes.txt`: length and SHA-256 of `ClientContextBuilder.build()` for MTG-0013..0019 (Day 4 snapshot,
    2026-10-13, BUILD_LOG step 2).
  - `summary_replay.txt`: the last recorded replay of the saved Option A outputs through SummaryValidator (2026-10-12,
    after the amount-conflict check; BUILD_LOG conflict row).
  - `prep_replay.txt`: the last recorded replay of the saved prep outputs through CitationValidator with the other
    visible clients passed in (2026-10-13, BUILD_LOG sample-accounts row).
