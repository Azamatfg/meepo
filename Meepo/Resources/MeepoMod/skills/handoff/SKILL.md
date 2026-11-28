---
name: handoff
description: Write this session's handoff so a fresh session (or another one, or you tomorrow) carries on without "where did we stop" — the task, what's done, decisions, files, next steps
disable-model-invocation: true
---

Write the handoff of this session to a file, then print its path.

1. The file: `~/.meepo/handoffs/<this project's folder name>/<YYYY-MM-DD-HHMM>-<2–4 word slug>.md`
   (create the folder). One file per handoff; never overwrite an older one.
2. In the language the user writes in, facts only, under 80 lines:
   - **Task** — what was asked, in one or two sentences, and where it comes from (issue, spec, chat).
   - **Done** — what changed, with commits or "uncommitted".
   - **Decisions** — what was chosen and why; what was tried and dropped, and why.
   - **Files** — paths, what each holds for this task.
   - **Next** — the next steps in order; the very next one first.
   - **Open questions** — what to ask the user.
   - **How to check** — the command or steps that show it works.
3. The last line of your reply, exactly: `HANDOFF: <absolute path of the file>`
