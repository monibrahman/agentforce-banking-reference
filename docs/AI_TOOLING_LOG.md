# AI tooling log

| Date | What the AI produced | Helped or misled | How I caught or corrected it |
| --- | --- | --- | --- |
| 2026-10-11 | Claude Code's Day 1 plan retrieved `CustomField:Opportunity.Type` to capture the new picklist values | Misled | Caught in plan review: I had the plan checked by a second AI reviewer (Claude chat) before approving. Standard picklist values live in StandardValueSet:OpportunityType. Plan fixed before running; retrieved file checked for M&A/ECM/DCM. |
| 2026-10-11 | Claude Code's first draft of ClientContextBuilder called `ctx.nextTag(...)` but defined the helper as a static `tagFor(ctx, ...)`, so it would not have compiled | Misled | Caught during review before the file was written: I paused the write to check the Opportunity query, and Claude Code found the mismatch on rereading. Fixed by making `nextTag` a method on `Context` and removing `tagFor` |
| 2026-10-11 | Claude Code's test asserted `ctx.amounts.contains(250000000)` on a `List<Decimal>` | Misled | 2 tests failed. Claude Code checked the cause in anonymous Apex before changing anything (`contains(Integer)` is false, `==` is true) and fixed the test, not the class |
| 2026-10-11 | Claude Code's seed script used `8400000000` (too big for an Integer literal; needs `L`) and claimed to be re-runnable without trying it | Misled | Compile error on first run; fixed with `8400000000L`. The re-run claim failed on the second run (Closed Won opportunities block account delete); fixed and verified with two runs in a row |
