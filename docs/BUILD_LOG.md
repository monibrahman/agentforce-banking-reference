# Build log

| Date | Symptom | Root cause | Fix | Lesson |
| --- | --- | --- | --- | --- |
| 2026-10-11 | Seed deals need M&A / ECM / DCM, but Opportunity.Type only had the default values | Standard picklist values ship with Salesforce defaults | **Manual Setup step (owner):** added M&A, ECM, DCM to Opportunity > Type (defaults kept). Retrieved as `StandardValueSet:OpportunityType` | Standard picklist values live in a StandardValueSet, not on the field; retrieve that to put them in source control |
