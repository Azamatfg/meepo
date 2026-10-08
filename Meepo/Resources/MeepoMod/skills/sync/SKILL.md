---
name: sync
description: Save what this session learned to CLAUDE.md and the spec, so the next session starts with it
disable-model-invocation: true
---

Make sure the next session knows what this one learned.

1. If a spec in docs/specs/ covers this work, mark what's done and what's next there.
2. Add to the project's CLAUDE.md only what Claude would get wrong without it: a command that works differently,
   a convention, a trap we hit. Not what the code or git history already says.
3. Keep CLAUDE.md short: for each line ask "would Claude make a mistake without it?" — remove the ones that
   fail, and outdated ones.
4. Show me what changed in each file, in a sentence each.
