# Meepo

> One player. Many agents. Press Tab.

Meepo is a native macOS control panel for running several [Claude Code](https://claude.com/claude-code) sessions across projects at once. It replaces "a VS Code window, a terminal and `claude` per project" with one window: every session is a unit on the map, and the ones waiting for you glow orange.

<!-- Screenshot: main window with three projects, one session waiting -->
<!-- GIF: Option+Tab through sessions, answering a permission request -->

## What it does

- **Sessions side by side.** Real terminals (SwiftTerm) running `claude`, grouped by project. `Option+Tab` / `Option+Shift+Tab` moves between them, `Ctrl+Tab` jumps to the next one that is waiting for you.
- **Knows what each session needs.** A hook bridge reports status, permission requests, questions and failures; notifications say *which* session wants *what*.
- **Stages.** PLAN → CODE → QA → SHIP → SYNC per session, each a click that runs your own slash command. Meepo reminds you to QA again if code changed after the last QA.
- **Context and tokens.** Context-window bar per session, tokens today, stats by project and model; when a session gets full, Meepo relays it into a fresh one with a summary.
- **What the agent changed.** Next to each session: every file it touched since it started, committed or not, with PUSH/PULL. COMPARE opens the diff exactly as VS Code shows it (it's VS Code's own editor, Monaco); EXPLAIN says what changed in plain words.
- **Parallel features.** New sessions in their own git worktree (`claude -w`) with their own port range.
- **Mornings and evenings.** Turn a task list into running sessions with one button; end-of-day summary per project with commits, stages, tokens and the TODOs the agent left.
- **Screenshots straight into a session.** A global hotkey captures an area and pastes it into the selected session. No files are saved.
- **CI.** GitHub Actions (`gh`) and GitLab CI (`glab`): each project's default-branch pipeline step by step, with a RUN button for the manual deploy step. Failed runs can be rerun, or fixed by a new session that opens a PR. Meepo never pushes to main and never fixes a deploy on its own.
- **Tools.** Compare commands, hooks and agents across projects against a shared library (DIFF, LIFT, OVERWRITE, with backups). Clean up stopped Docker containers by project.
- **Release notes.** Draft a post about the commits since the last one, in the voice of your own sample posts. You edit it and copy it wherever it goes.
- **Import from Claude Code.** Every folder you've worked on with Claude Code — from any editor or a terminal — comes in with one click, with its latest conversation to continue (`claude --resume`). Folders without git work too. Every project has an "Open in VS Code / Cursor / Zed" menu, because Meepo has no editor of its own.
- **Desktop widget.** Tokens today, running sessions, waiting sessions.

## Requirements

- macOS 14 or later, Apple silicon or Intel
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude`) and `git`
- Optional: `gh` (GitHub CI), `glab` (GitLab CI), Docker

On first launch Meepo checks for these and shows how to install anything that is missing.

## Install

```bash
brew tap azamatfg/meepo
brew trust azamatfg/meepo     # newer Homebrew asks you to trust third-party taps once
brew install --cask meepo
```

Then `meepo` opens it from any terminal, and `meepo .` adds the current folder as a project with a Claude session in it.

Or download `Meepo.zip` from [Releases](https://github.com/Azamatfg/meepo/releases), unzip it and move `Meepo.app` to Applications. Builds are signed and notarized by Apple, so macOS opens them without warnings.

### Build from source

```bash
brew install xcodegen
git clone https://github.com/Azamatfg/meepo && cd meepo
xcodegen generate
xcodebuild -downloadComponent MetalToolchain   # once, for SwiftTerm's shaders
xcodebuild -project Meepo.xcodeproj -scheme Meepo -skipPackagePluginValidation build
```

## Your phone

Meepo is the control panel on your Mac. On your phone, use the official Claude app through Claude Code's **Remote Control**:

- **Settings → Remote Control for new sessions** starts sessions with `claude --remote-control "project · branch"`. They show up under those names in the Claude app and on claude.ai. This needs a claude.ai login.
- **PHONE** on a running session turns Remote Control on without restarting it.

From the phone you can see that a session is waiting, read the request and approve it.

## Security

- Meepo talks to Claude Code through hooks. The bridge posts to a server that listens on `127.0.0.1` only, and every request carries a local token from `~/.meepo/token`.
- Meepo stores no API keys or passwords. GitHub, GitLab and Claude use their own CLIs and logins (`gh`, `glab`, `claude`).
- It never pushes to main/master, never force-pushes, and never fixes a failing deploy automatically. Deploys start only when you click RUN and confirm.
- Changes to your files (the hook bridge in `~/.claude/settings.json`, shared commands in Tools) are backed up to `~/.meepo/backups` first.
- Release notes are written by `claude -p` with no tools and no settings files, so nothing runs and no hooks fire.

## Data

Everything lives on your Mac: `~/.meepo/meepo.sqlite` (sessions, events, tasks, notes), `~/.meepo/backups`, `~/.meepo/release-style.md`. Token usage is read from Claude Code's own transcripts in `~/.claude/projects`.

## License

MIT — see [LICENSE](LICENSE). The compare view bundles [Monaco Editor](https://github.com/microsoft/monaco-editor) (MIT), the editor behind VS Code.
