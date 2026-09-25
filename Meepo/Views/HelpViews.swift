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
        case .explorer: "The files of the selected session's project. Files Claude changed are colored like in VS Code. Click a file to read it."
        case .changes: "What changed in git: CHANGES are edits not committed yet, INCOMING are your teammates' new commits, OUTGOING are commits not pushed yet. Compare shows the difference; Explain says it in plain words."
        case .ci: "Your project's builds, tests and deploys (GitHub Actions or GitLab CI). A step waiting for a click — like deploy — gets a Run button."
        case .events: "Everything the agent did in this session, step by step: your requests, the tools it used, when it finished."
        case .waiting: "Sessions that stopped and wait for you — a question, a permission, or a finished task. Ctrl+Tab jumps to the next one."
        case .product: "Each request you gave Claude is a run. Explain for users turns a finished run into plain words: what your users will notice, what to check before shipping, how to try it."
        }
    }

    static let home = "Home shows all sessions at once. Deck: a card per session with its state and last step. Timeline: the last hour, one square per minute — blue when Claude worked, orange when it waited for you, empty when nothing happened."

    static let stages = "Your workflow, left to right: PLAN thinks it through, CODE builds, QA checks, SECU looks for security holes, SIMP tidies the code, SHIP commits and pushes, SYNC saves what was learned. Click a stage to run it; the outlined one is next. Grey means this project has no command for it."

    static let presets = "Focus: one terminal and what changed. Deck: up to four sessions at once. Full: files, git and two terminals, like VS Code. Move any panel yourself and it's saved as Custom."
}

/// ≡ → How Meepo works: the whole app on one page.
struct GuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(String, String)] = [
        ("The idea", "You tell Claude Code what to build; Meepo keeps every session in one window and shows what's going on — who works, who waits for you, what changed."),
        ("Sessions", "A session is one Claude conversation in a project. Start one with + (New Session). Give it a name to tell two sessions of one project apart. Ctrl+Tab jumps to the session that needs you; Option+Tab to the next one."),
        ("Tabs and Home", "Tabs at the top: Home, then every session. " + Explain.home),
        ("Layout", Explain.presets + " The icons on the left show or hide panels; point at one to see its name."),
        ("Stages", Explain.stages),
        ("What changed", Explain.panel(.product)),
        ("Git and CI", Explain.panel(.changes) + " Teammates' commits come in by themselves when your work is committed. " + Explain.panel(.ci)),
        ("Automations", "≡ → Automations: your skills and commands and how often you use them. Meepo notices what you repeat — commands in a row, requests you keep typing — and offers a button or a skill for it."),
        ("Guided mode", "≡ → Guided mode: Claude explains what it does, and asks before anything risky (push, deleting folders, secrets). For people new to Claude Code."),
        ("Updates", "Meepo updates itself: when a new version is downloaded, the status bar says so — Restart, or it installs when you quit."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("How Meepo works").font(Fonts.title(26))
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
