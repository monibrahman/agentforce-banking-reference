# AI tooling log

| Date | What the AI produced | Helped or misled | How I caught or corrected it |
| --- | --- | --- | --- |
| 2026-10-11 | Claude Code's Day 1 plan retrieved `CustomField:Opportunity.Type` to capture the new picklist values | Misled | Caught in plan review: I had the plan checked by a second AI reviewer (Claude chat) before approving. Standard picklist values live in StandardValueSet:OpportunityType. Plan fixed before running; retrieved file checked for M&A/ECM/DCM. |
| 2026-10-11 | Claude Code's first draft of ClientContextBuilder called `ctx.nextTag(...)` but defined the helper as a static `tagFor(ctx, ...)`, so it would not have compiled | Misled | Caught during review before the file was written: I paused the write to check the Opportunity query, and Claude Code found the mismatch on rereading. Fixed by making `nextTag` a method on `Context` and removing `tagFor` |
