import SwiftUI

/// A small "?" that explains the thing next to it in two or three plain sentences — Meepo has words and icons
/// people meet for the first time (tester: "not everything is obvious").
struct InfoButton: View {
    let title: String
    let text: String
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.textDim)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What is \(title)?")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Fonts.ui(14, weight: .bold))
                Text(text).font(Fonts.ui(13)).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .paperSheet()
        }
    }
}

/// Plain-words explanations, one place for all of them.
enum Explain {
    static func panel(_ panel: ShellLayout.Panel) -> String {
        switch panel {
        case .sessions: "Every Claude session, grouped by project. The dot is its state: blue working, orange waiting for you, grey ready. Click one to open its terminal; + starts a new one in that project."
        case .explorer: "The files of the selected session's project. Files Claude changed are colored like in VS Code. Click a file to read it; drop files from Finder to copy them in (onto a folder: into it). Or copy them in Finder (⌘C), click a folder here and press ⌘V — or right-click it → Paste. A click here takes the keyboard from Claude; Esc or a click in the terminal gives it back. Nothing is overwritten: a taken name becomes \"name 2\"."
        case .changes: "What changed in git: CHANGES are edits not committed yet, INCOMING are your teammates' new commits, OUTGOING are commits not pushed yet, HISTORY the branch's last commits — click one for its hash, message and files. Compare shows the difference; Explain says it in plain words."
        case .ci: "The selected tab's project: its builds, tests and deploys (GitHub Actions or GitLab CI). A step waiting for a click — like deploy — gets a Run button. All projects shows every project's CI."
        case .events: "What Claude did in this session, step by step, in plain words: what you asked, the commands it ran, the files it read or edited. Click a step for the details; a file opens in the editor."
        case .waiting: "Sessions that stopped and wait for you — a question, a permission, or a finished task. Ctrl+Tab jumps to the next one."
        case .product: "What you sent, push by push: each with its commits and the requests that led to it — and on top, what isn't sent yet (not committed, not pushed) and the next step. Explain for users says it in your product's words: what changes for your users, section by section, what to check before you ship, how to try it. It's written on your click from the commits, your requests and Claude's answers — a small request, not a re-read of the whole conversation."
        }
    }

    static let home = "Home shows all sessions at once. Deck: a card per session — does it need you (a permission, a question), how its last request ended, and what isn't sent yet. Today: what you sent today, project by project, and what's left; ▸ shows the requests behind a push and what Claude answered. Click any of them to open the session."

    static let elsewhere = "Claude sessions meepo didn't start. BACKGROUND is an agent that works on its own, with no window (claude --bg or the agent view): Open here shows it as a meepo tab — closing the tab never stops it; Stop does, and keeps its conversation. Output shows what it printed last. IN VS CODE, TERMINAL… is claude open in another app: one conversation runs in one place at a time, so once you close it there, Continue here picks it up in meepo (claude --resume). One that waits for your answer counts in \"need you\"."

    static let databases = "Your projects' Postgres, for Claude to read — never to change. meepo makes a role that can only read (SELECT), switches Claude's postgres server in .mcp.json to it, and draws the schema. The database itself refuses any change from that role, whatever is asked."
    static let stages = "Your workflow, left to right: PLAN thinks it through, CODE builds, QA checks, SECU looks for security holes, SIMP tidies the code, SHIP commits and pushes, SYNC saves what was learned. Click a stage to run it. The lit one is what to press now: SIMP once Claude has changed code, then SHIP, then SYNC. Grey means this project has no command for it. Right-click a stage to hide it or bring others back."

    static let workflows = "A workflow is your own automation, written as a plain Claude Code file. A button runs steps in order (a skill of yours: /name works in any terminal); right-click it to repeat it every few minutes (/loop) or schedule it in the cloud (/schedule). A step is a command or plain words for Claude. Need a command you don't have? Add a command → New command… makes one of yours — or ask Claude in a session: “make me a /name command that …”. A check runs after every answer Claude gives (a Stop hook) — if it fails, Claude fixes it. Workflows with several agents at once are Claude Code's own: save one from Claude Code and meepo shows it under WORKFLOWS."

    static func dockerSpace(_ total: String) -> String {
        "Docker keeps what it downloaded or built for your projects (images — the programs their containers run) and each project's saved data (volumes — its database, uploads) — about \(total) on this Mac. Images nothing uses are safe to clear; saved data is yours to keep or delete."
    }

    static let ports = "A port is a numbered door a program opens on this Mac: a dev server on 3000 is what localhost:3000 shows in the browser. One left running keeps its port busy, and the next can't start there (\"address already in use\") — Stop frees it. Grouped by project: programs started in its folder, its Docker containers, and each session's own ports — Open shows one in the browser."

    static let servers = "The servers your projects run on, and where their logs are. meepo logs in with your own ssh (the keys and agent you already use — it stores no keys and never asks for a password) and only ever reads logs: the last 200 lines of a service (journalctl), a container (docker logs) or a file (tail) — nothing else runs there. Get logs, then paste them into the project's session and ask Claude, or start a new session that looks into them. When a deploy fails, the CI tab offers the same."

    static let presets = "Focus: one terminal and what changed. Deck: up to four sessions at once. Full: files, git and two terminals, like VS Code. Change any of them — move, hide or add panels — and it stays that way; a • marks a changed one, right-click it to reset."
}

/// ≡ → How Meepo works: the whole app on one page.
struct GuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(String, String)] = [
        ("The idea", "You tell Claude Code what to build; meepo keeps every session in one window and shows what's going on — who works, who waits for you, what changed."),
        ("Sessions", "A session is one Claude conversation in a project. Start one with + (New Session). Drop files or screenshots on its terminal: images reach Claude as images, other files as their paths. Give it a name to tell two sessions of one project apart. Ctrl+Tab jumps to the session that needs you; Option+Tab to the next one."),
        ("Tabs and Home", "Tabs at the top: Home, then every session. " + Explain.home),
        ("Layout", Explain.presets + " The icons on the left show or hide panels; point at one to see its name."),
        ("Stages", Explain.stages),
        ("What changed", Explain.panel(.product)),
        ("Git and CI", Explain.panel(.changes) + " Teammates' commits come in by themselves when your work is committed. " + Explain.panel(.ci)),
        ("Automations", "≡ → Automations: your skills and commands and how often you use them. meepo notices what you repeat — commands in a row, requests you keep typing — and offers a button or a skill for it. New workflow… builds your own: " + Explain.workflows),
        ("Guided mode", "≡ → Guided mode: Claude explains what it does and why, and asks before anything risky (a push, deleting folders, sudo, publishing, editing .env secrets) — even in auto mode. For people new to Claude Code. claude reads it when it starts, so switching it offers to restart the sessions that are between turns; the conversation goes on where it was. A session running guided says · guided next to its model."),
        ("Voice", "VOICE under a terminal turns on Claude Code's voice dictation (/voice) for every session: hold Space, speak, let go, and what you said appears in the prompt. The first click asks macOS whether meepo may use the microphone. It needs a Claude.ai sign-in, so the button is hidden with an API key."),
        ("Tools", "≡ → Tools. Docker: where its disk space went, one Clear for what nothing uses, and each project's saved data — Delete only where no container uses it. Ports: what listens on this Mac, by project; Open a session's own port, Stop a program of yours. Changes: every file meepo changed, with Restore. Nothing happens without your OK."),
        ("Updates", "meepo updates itself: when a new version is downloaded, the status bar says so — Restart, or it installs when you quit."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("How meepo works").font(Fonts.title(26))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections, id: \.0) { title, text in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(Fonts.ui(16, weight: .bold))
                            Text(text).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 640, height: 620)
        .paperSheet()
    }
}
