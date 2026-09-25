import AppKit
import SwiftUI

/// First launch: two ways in. Someone who already uses Claude Code brings what they have — Claude Code, the
/// statuses bridge, their projects. Someone new gets Claude Code installed and signed in, a first project, and
/// Guided mode. Reopen any time from ≡ → Welcome.
struct OnboardingView: View {
    enum Path { case experienced, new }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var path: Path?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch path {
            case nil: ChoosePath { path = $0 }
            case .experienced?: ExperiencedSetup(back: { path = nil }, finish: finish)
            case .new?: NewcomerSetup(back: { path = nil }, finish: finish)
            }
        }
        .frame(width: 820, height: 680)
        .paperSheet()
    }

    private func finish(_ path: Path, guided: Bool) {
        store.guidedMode = guided
        store.applyPreset(path == .new ? .focus : .full)
        dismiss()
    }
}

// MARK: The choice

private struct ChoosePath: View {
    @Environment(\.dismiss) private var dismiss
    let choose: (OnboardingView.Path) -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack { Spacer(); Button("Skip") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle(compact: true)) }
            Text("You describe. Claude Code builds.").font(Fonts.ui(40, weight: .bold)).multilineTextAlignment(.center)
            Text("meepo keeps every Claude Code session on track. How do you want to start?")
                .font(Fonts.ui(17)).foregroundStyle(Tokens.textDim)
            HStack(alignment: .top, spacing: 18) {
                card("I already use Claude Code",
                     "meepo reads what Claude Code already has. Your setup stays yours.",
                     ["Your projects and conversations, found for you",
                      "Your skills, hooks and settings, untouched — Automations shows how you use them",
                      "Explorer, Source Control and two terminals side by side"],
                     "Bring my setup") { choose(.experienced) }
                card("I'm new to this",
                     "Tell Claude what to build; meepo explains each step in plain words.",
                     ["Claude Code installed and signed in, step by step",
                      "A first project — a folder you have, or a new one",
                      "Guided mode: Claude explains, and asks before anything risky",
                      "What changed shown for your users, not as code"],
                     "Start guided") { choose(.new) }
            }
            Spacer(minLength: 0)
            Text("Everything here can be changed later: ≡ → Welcome, Guided mode, layout presets.")
                .font(.caption).foregroundStyle(Tokens.textDim)
        }
        .padding(28)
    }

    private func card(_ title: String, _ subtitle: String, _ points: [String], _ action: String,
                      perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Fonts.ui(24, weight: .bold))
            Text(subtitle).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            ForEach(points, id: \.self) { point in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("✓").foregroundStyle(Tokens.work)
                    Text(point).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button(action, action: perform).buttonStyle(PixelButtonStyle(large: true, isPrimary: true))
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: 360, alignment: .topLeading)
        .background(Tokens.raised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Tokens.line))
    }
}

// MARK: Shared steps

/// A numbered step: title, what it is, and its state or action.
private struct Step<Content: View>: View {
    let number: Int
    let title: String
    let isDone: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(isDone ? Tokens.work : Tokens.ghost).frame(width: 28, height: 28)
                Text(isDone ? "✓" : "\(number)").font(Fonts.ui(14, weight: .bold)).foregroundStyle(isDone ? Tokens.raised : Tokens.text)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Fonts.ui(18, weight: .bold))
                content
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokens.line))
    }
}

/// Claude Code found and signed in — or exactly what to do about it.
private struct ClaudeStep: View {
    @Environment(AppStore.self) private var store
    let number: Int
    let isNewcomer: Bool
    @State private var isChecking = false

    var body: some View {
        let found = store.loginEnvironment != nil
        let signedIn = store.isClaudeLoggedIn == true
        Step(number: number, title: "Claude Code", isDone: found && signedIn) {
            if !store.isLoginResolved {
                Text("Looking for claude…").foregroundStyle(Tokens.textDim)
            } else if !found {
                Text(isNewcomer ? "Claude Code is the assistant that does the work. Install it: open Terminal, paste this, press Enter."
                                : "claude isn't on your login shell's PATH. Install it, or check ~/.zshrc:")
                    .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                command("curl -fsSL https://claude.ai/install.sh | bash")
            } else if !signedIn {
                Text(isNewcomer ? "Now sign in: in Terminal type claude, press Enter and follow the browser. A Claude subscription (Pro or Max) covers it."
                                : "Not signed in — run claude once in Terminal and sign in.")
                    .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                command("claude")
            } else {
                Text("Found \(store.claudeVersion.map { "Claude Code \($0)" } ?? "claude"), signed in.").foregroundStyle(Tokens.textDim)
            }
            if !(found && signedIn), store.isLoginResolved {
                Button(isChecking ? "Checking…" : "Check again") {
                    isChecking = true
                    Task {
                        if !found { await store.resolveLogin() } else { await store.checkClaudeLogin() }
                        isChecking = false
                    }
                }
                .buttonStyle(PixelButtonStyle(compact: true))
                .disabled(isChecking)
            }
        }
    }

    private func command(_ text: String) -> some View {
        HStack {
            Text(text).font(Fonts.mono(13)).textSelection(.enabled)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(PixelButtonStyle(compact: true))
        }
        .padding(10)
        .background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The hook bridge, with what it changes said plainly before the user agrees.
private struct BridgeStep: View {
    @Environment(AppStore.self) private var store
    let number: Int

    var body: some View {
        Step(number: number, title: "See what every session is doing", isDone: store.isBridgeInstalled) {
            Text("So meepo can show who's working, who waits for you and what changed, Claude Code tells it through hooks.")
                .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            if store.isBridgeInstalled {
                Text("On. Remove it any time: meepo menu → Remove Hook Bridge.").foregroundStyle(Tokens.work)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("What this changes:").font(Fonts.ui(13, weight: .semibold))
                    Text("• ~/.claude/settings.json gets \(BridgeInstaller.events.count) hook entries that call ~/.meepo/bin/meepo-bridge.sh")
                    Text("• your own hooks and settings stay as they are; a backup goes to ~/.meepo/backups")
                    Text("• sessions outside meepo aren't affected, and if meepo is removed the entries do nothing")
                }
                .font(.caption).foregroundStyle(Tokens.textDim)
                Button("Turn on") { store.installBridge() }.buttonStyle(PixelButtonStyle(isPrimary: true))
            }
        }
    }
}

private struct Header: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack {
            Button("← Back", action: back).buttonStyle(PixelButtonStyle(compact: true))
            Text(title).font(Fonts.ui(26, weight: .bold)).padding(.leading, 8)
            Spacer()
        }
    }
}

// MARK: Already using Claude Code

private struct ExperiencedSetup: View {
    @Environment(AppStore.self) private var store
    let back: () -> Void
    let finish: (OnboardingView.Path, Bool) -> Void

    private static let optional = [("gh", "GitHub CI and pull requests", "brew install gh && gh auth login"),
                                   ("glab", "GitLab CI", "brew install glab && glab auth login")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(title: "Bring your setup", back: back)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ClaudeStep(number: 1, isNewcomer: false)
                    BridgeStep(number: 2)
                    Step(number: 3, title: "Your projects", isDone: !store.projects.isEmpty) {
                        Text("Folders you've worked in with Claude Code. Pick the ones to bring in; conversations can continue where they stopped.")
                            .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                        ImportList {}.frame(minHeight: 220)
                        Text("In a teammate's repo for the first time? Run /team-onboarding in a session there: Claude Code writes a guide from how the team works.")
                            .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                    Step(number: 4, title: "Optional: CI in meepo", isDone: Self.optional.allSatisfy { store.toolPath($0.0) != nil }) {
                        ForEach(Self.optional, id: \.0) { name, use, install in
                            HStack(spacing: 8) {
                                Text(store.toolPath(name) != nil ? "✓" : "–").foregroundStyle(Tokens.work)
                                Text(name).font(Fonts.mono(13))
                                Text(use).font(.caption).foregroundStyle(Tokens.textDim)
                                Spacer()
                                if store.toolPath(name) == nil { Text(install).font(Fonts.mono(11)).textSelection(.enabled) }
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Open meepo") { finish(.experienced, false) }.buttonStyle(PixelButtonStyle(large: true, isPrimary: true))
            }
        }
        .padding(24)
    }
}

// MARK: New to Claude Code

private struct NewcomerSetup: View {
    @Environment(AppStore.self) private var store
    let back: () -> Void
    let finish: (OnboardingView.Path, Bool) -> Void
    @State private var guided = true
    @State private var projectName = ""
    @State private var isPickingFolder = false
    @State private var error: String?

    private var parent: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Projects") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(title: "Start guided", back: back)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ClaudeStep(number: 1, isNewcomer: true)
                    BridgeStep(number: 2)
                    Step(number: 3, title: "Your first project", isDone: !store.projects.isEmpty) {
                        if let project = store.projects.first {
                            Text("\(project.name) — \(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))").foregroundStyle(Tokens.work)
                        } else {
                            Text("A project is a folder Claude works in. Start a new one, or use a folder you already have.")
                                .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                TextField("my-first-app", text: $projectName).textFieldStyle(.roundedBorder).frame(width: 220)
                                Button("Create in ~/Projects") {
                                    do { try store.createProject(named: projectName, in: parent); error = nil }
                                    catch { self.error = error.localizedDescription }
                                }
                                .buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
                                .disabled(projectName.trimmingCharacters(in: .whitespaces).isEmpty)
                                Text("or").foregroundStyle(Tokens.textDim)
                                Button("Choose a folder…") { isPickingFolder = true }.buttonStyle(PixelButtonStyle(compact: true))
                            }
                            Text("A new project gets git, so every change is kept and can be compared or undone. Nothing is uploaded anywhere.")
                                .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                        }
                        if let error { Text(error).font(.caption).foregroundStyle(Tokens.danger) }
                    }
                    Step(number: 4, title: "Guided mode", isDone: guided) {
                        Toggle("Explain as you go, and ask me before anything risky", isOn: $guided).toggleStyle(.switch)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("• Claude explains what it does and why (Claude Code's Explanatory style)")
                            Text("• it asks first before pushing code, deleting folders, using sudo, publishing, or touching .env secrets")
                            Text("• only in meepo's sessions; turn it off later in ≡ → Guided mode")
                        }
                        .font(.caption).foregroundStyle(Tokens.textDim)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Start") { finish(.new, guided) }.buttonStyle(PixelButtonStyle(large: true, isPrimary: true))
            }
        }
        .padding(24)
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            do { try store.addProject(at: result.get()); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}
