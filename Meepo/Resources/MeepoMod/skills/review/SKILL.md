---
name: review
description: Review the changes in a fresh context for correctness and the spec only, before shipping
disable-model-invocation: true
---

Review what's about to ship — uncommitted changes and commits not pushed yet — with fresh eyes.

1. Hand the review to a subagent (Agent tool), so it reads the code without knowing how it was written. Give it
   the diff range and, if one matches, the spec in docs/specs/.
2. It reports only:
   - **Critical** — a bug, a crash, data loss, a security hole, or the code doesn't do what the spec says
   - **Optional** — anything else worth a look
   Style, naming and "could be cleaner" are not findings: chasing every remark makes code worse.
3. Fix the Critical ones, run the project's check again, and show me its result. List the Optional ones for me to
   decide; don't change code for them.
