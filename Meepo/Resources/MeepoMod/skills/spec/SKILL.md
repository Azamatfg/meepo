---
name: spec
description: Interview me about a feature, then write its spec to docs/specs/ before any planning or code
argument-hint: "[what to build]"
disable-model-invocation: true
---

Before any plan or code, find out what to build and write it down. The feature: $ARGUMENTS

1. Read what the project already has on it (code, docs/specs/, CLAUDE.md), so you don't ask what the code answers.
2. Interview me with the AskUserQuestion tool, one question at a time: what it is for and who uses it, what
   it must not do, edge cases, UI, tradeoffs, how we'll know it works. Skip the obvious; dig into the hard
   parts I may not have thought about. Offer your recommendation first among the options.
3. Stop when the open questions are answered, then write `docs/specs/<short-feature-name>.md`:
   - **Goal** — what and why, in a user's words
   - **Not doing** — what's out of scope
   - **Decisions** — what we chose and why
   - **How we check it** — the commands, tests or screens that prove the whole feature works
   - **Open questions** — if any remain
4. Show me the spec's path and its Goal. Don't plan or code here: the plan starts in a fresh session that reads
   this file, so nothing from this interview has to be remembered.
