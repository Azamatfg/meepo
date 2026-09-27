# meepo

> A comfortable home for Claude Code on your Mac.

[Claude Code](https://claude.com/claude-code) is a great way to build software. meepo makes it easier to live with every day: all your Claude Code sessions in one window, a glance at which one is working and which one waits for you, and what changed — in your product's terms, not just in the code.

meepo doesn't write code and isn't another agent. Claude Code does the work, with your own settings, skills and hooks; meepo is the place around it.

![Home: every session at a glance](docs/screenshots/home.png)

## What it does

**Every session in one window.** Tabs for each Claude session across your projects, up to four terminals side by side, `Ctrl+Tab` to the session that needs you. Home answers the questions you'd otherwise check tab by tab: *Deck* — for each session, is it waiting on me, how did the last request end, what isn't sent yet; *Today* — what you sent today, project by project, and what's still left (a file not committed, a deploy waiting for your click, a question Claude asked).

![Four sessions: working, waiting for a permission, waiting for an answer, ready](docs/screenshots/deck.png)

![Today: what was sent and what's left](docs/screenshots/today.png)

**What changed — in your product's terms.** Work is counted the way it reaches people: by push. *What changed* shows a block for each push ("Sent to GitHub · 11:53 · 2 commits") and one for what isn't sent yet, with the requests behind it and the next step. One click writes it for your users — "in Leasing you can now import a payment schedule from Excel" — with what to check before shipping and how to try it. The code diff is still one click away.

![What changed: a run explained for users](docs/screenshots/focus.png)

**Your layout, set once.** Focus (one terminal and what changed), Deck (four sessions), Full (Explorer, Source Control and two terminals, like VS Code). Move, hide or add panels and that layout keeps it; right-click to reset. Every panel names its project and has a **?**.

![Full: Explorer, Source Control, two terminals, events and CI](docs/screenshots/full.png)

**Git like VS Code, teammates included.** CHANGES, INCOMING, OUTGOING and HISTORY per repo — click a commit for its message, files and page on GitHub or GitLab — with Compare in VS Code's own editor (Monaco) and Explain in plain words. Teammates' commits come in by themselves once your work is committed, and the agent is told what changed under it. Projects that hold several repos, and sessions that also work in a second project (`claude --add-dir`), show every repo.

**Files in, screenshots in.** Drop a screenshot on a terminal and Claude gets it as an image; drop or paste (⌘V) files into Explorer to copy them into the project.

**Talk instead of typing.** VOICE turns on Claude Code's own dictation: click SPEAK, talk, click SEND — no key to hold.

**CI and deploys.** GitHub Actions and GitLab CI as the steps of your latest commit — what each step does, how long it took, a live clock while it runs, and one line on what's up to you. Run for a deploy (always confirmed), Fix with Claude for a failure, Rerun, and the log.

**Knows Claude Code.**
- Plan limits (5 hours, 7 days) with reset times, the real model and effort of each session, context as Claude Code counts it.
- *New in Claude Code*: after an update, the changes that touch your setup come first.
- *Claude Code Setup*: finds things that quietly work against you — an effort level that no longer reaches the model you use, hook timeouts written in milliseconds, allow rules like `Bash(sudo:*)`, skills that push which Claude may start by itself — each with a fix and an exact undo.

**Learns from how you work.** *Automations* shows your skills and commands with how often you really use them, effort and model per skill, and which ones Claude may start by itself. meepo notices what you repeat — commands in a row, requests you keep typing — and offers a button or a personal skill for it, and *New command…* makes one from a sentence. Then it checks whether it helped.

**Workflows of your own.** *New workflow…* builds automations as plain Claude Code files, shown before they're saved: a button that runs steps in order (a skill of yours, so `/name` works in any terminal), which you can repeat while a session is open (`/loop`) or schedule in the cloud (`/schedule`); and a check after every answer (a Stop hook: if `npm test` fails, Claude reads why and fixes it). Workflows with several agents at once are Claude Code's own — save one there and meepo lists it with a Run button.

**Stages.** PLAN → CODE → QA → SECURITY → SIMPLIFY → SHIP → SYNC, each a click that runs your own command — or Claude Code's built-in one (`/verify`, `/security-review`, `/commit-push-pr`) when a project has none.

**For people new to Claude Code.** Onboarding installs and signs in Claude Code step by step and lets you pick or create the folder Claude works in. *Guided mode* makes Claude explain what it does and ask before anything risky — pushing, deleting folders, `sudo`, publishing a package, editing `.env` secrets — and offers to restart the sessions that aren't mid-turn so it applies right away.

**Around the work.** *Tools* shows where Docker's disk space went and clears only what's safe, lists which program holds which port by project (Stop only for your own), and keeps every change meepo made to your files, undoable. *Notes* turns what you shipped into release notes to paste into Telegram or Slack, formatted.

## Built on Claude Code

Everything meepo shows comes from Claude Code itself, and everything it does goes through it:

- the real `claude` CLI in each terminal, with your login, settings, skills, hooks and memory
- Claude Code's own hooks and statusline for what each session is doing, its plan limits and effort
- Claude Code's built-in commands and features where they exist — `/verify`, `/security-review`, `/commit-push-pr`, `/rewind`, worktrees, `--add-dir`, Remote Control, output styles, `skillOverrides`
- Claude Code's own changelog, to point out what a new release means for your setup

meepo follows Claude Code as it grows: when Claude Code gains something, meepo uses it rather than building its own.

## Install

macOS 14 or later. You need [Claude Code](https://docs.claude.com/en/docs/claude-code) and `git`; `gh` / `glab` for CI.

```bash
brew tap azamatfg/meepo
brew trust azamatfg/meepo     # newer Homebrew asks you to trust third-party taps once
brew install --cask meepo
```

`meepo` opens it from any terminal; `meepo .` adds the current folder with a session in it.

meepo updates itself: new versions download in the background, and the status bar offers a restart (or it installs when you quit). `meepo update` checks right away. Updates install only if they are signed by the same developer and notarized by Apple.

Or download `Meepo.zip` from [Releases](https://github.com/Azamatfg/meepo/releases) and move `Meepo.app` to Applications.

### Try it without your projects

```bash
open -n -a Meepo --args --demo
```

Made-up projects, no `claude` started, nothing of yours read or written — for a look around, screenshots or a demo.

### Uninstall

meepo menu → **Remove Hook Bridge** takes its hooks out of `~/.claude/settings.json`; then `brew uninstall --cask meepo` (add `--zap` to delete `~/.meepo`). If you skip the first step, the leftover hook entries do nothing.

## Your phone

meepo is the control panel on your Mac. On your phone, use the Claude app through Claude Code's **Remote Control**: turn it on for new sessions in Settings, or press **PHONE** on a running one. From the phone you can see that a session is waiting, read the request and answer it.

## Privacy and safety

- Everything stays on your Mac: `~/.meepo/meepo.sqlite`, backups in `~/.meepo/backups`. No telemetry. A crash report is shown to you to copy, never sent.
- meepo talks to Claude Code through hooks and a statusline, posted to a server on `127.0.0.1` only, with a local token.
- It stores no API keys or passwords; GitHub, GitLab and Claude use their own CLIs and logins.
- `claude -p` runs only when you click (Explain, drafts, release notes) — one short call, never with tools or your hooks.
- A button never answers for you: while Claude asks for a permission or asks a question, meepo types nothing that ends in Enter.
- Push, pull and deploy happen on your click with a confirmation; meepo never force-pushes. Quitting while an agent works asks first.
- Every change meepo makes to your files is backed up and can be undone (≡ → Tools → Changes); team files under git are never edited.

## Build from source

```bash
brew install xcodegen
git clone https://github.com/Azamatfg/meepo && cd meepo
xcodegen generate
xcodebuild -downloadComponent MetalToolchain   # once, for SwiftTerm's shaders
xcodebuild -project Meepo.xcodeproj -scheme Meepo -skipPackagePluginValidation build
```

Screenshots in this README come from demo mode: `TEST_RUNNER_MEEPO_SCREENSHOT_DIR=docs/screenshots xcodebuild … test -only-testing:MeepoTests/ShellSnapshotTests/testDemoScreens`.

## License

MIT — see [LICENSE](LICENSE). The compare view bundles [Monaco Editor](https://github.com/microsoft/monaco-editor) (MIT), the editor behind VS Code.
