import SwiftUI

/// Command bar under the terminal (SPEC module 4, design §5): the workflow stages as pixel buttons —
/// current one pressed in, next one lit — plus the project's other commands, "To code" and "Relay".
struct StagePanel: View {
    @Environment(AppStore.self) private var store
    let session: Session
    @State private var isMoreShown = false
    @State private var isPlanAsked = false
    @State private var missingStage: Stage?
    @State private var isHandoffShown = false
    @State private var handoffNotes = ""
    @State private var planTask = ""

    var body: some View {
        // Scrolls sideways when the window is narrow. Not ViewThatFits: on macOS 15 it measures its options on
        // SwiftUI's DisplayLink thread, building this row's ForEach there — a main-actor closure — which trapped
        // on every Option+Tab (the tester's crash, 2026-09-25).
        ScrollView(.horizontal, showsIndicators: false) { row }
            .padding(6)
            .background(Tokens.frameMid)
    }

    /// Stages, then session tools.
    @ViewBuilder
    private var row: some View {
        // All stages are always shown; ones this project lacks are dimmed and offer to add the command.
        let stages = store.stages
        let available = Set(store.stages(for: session.projectId).map(\.name))
        let current = stages.firstIndex { $0.name == session.stage }
        let next = current.map { $0 + 1 < stages.count ? $0 + 1 : nil } ?? 0
        HStack(spacing: 6) {
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                Button(stage.label) { available.contains(stage.name) ? run(stage) : (missingStage = stage) }
                    .buttonStyle(PixelButtonStyle())
                    .opacity(available.contains(stage.name) ? 1 : 0.4)
                    .popover(isPresented: Binding(get: { missingStage == stage }, set: { if !$0 { missingStage = nil } }),
                             arrowEdge: .top) {
                        MissingCommand(stage: stage, session: session) { missingStage = nil }
                    }
                    .popover(isPresented: Binding(get: { isPlanAsked && stage.command == "plan" }, set: { isPlanAsked = $0 }),
                             arrowEdge: .top) {
                        TaskPrompt(task: $planTask) { task in
                            isPlanAsked = false
                            planTask = ""
                            execute(task.isEmpty ? "plan" : "plan \(task)")
                        }
                    }
                    .overlay { if index == current { Capsule().fill(Tokens.work.opacity(0.14)).allowsHitTesting(false) } }
                    .overlay { if index == next { Capsule().strokeBorder(Tokens.work, lineWidth: 1.5) } }
                    .help(help(for: stage))
            }
            let others = (store.commandsByProject[session.projectId] ?? [])
                .filter { command in !stages.contains { $0.command == command.name } }
            if !others.isEmpty {
                Button("MORE ▾") { isMoreShown.toggle() }
                    .buttonStyle(PixelButtonStyle())
                    .popover(isPresented: $isMoreShown, arrowEdge: .top) {
                        CommandList(commands: others) { command in
                            isMoreShown = false
                            execute(command.name)
                        }
                    }
            }
            Spacer()
            Button("PHONE") { store.type("/remote-control\r", into: session.id!) }
                .buttonStyle(PixelButtonStyle())
                .help("Turn on Claude Code Remote Control: follow and answer this session from the Claude app or claude.ai")
            if let port = session.portBase {
                NumberPlate(text: "PORT \(port)").help("PORT / MEEPO_PORT_BASE for this session: \(port)–\(port + Ports.blockSize - 1)")
            }
            if store.mergedWorktreeSessionIds.contains(session.id!) {
                Button("REMOVE WORKTREE") {
                    store.confirmation = PixelConfirmation(
                        title: "REMOVE WORKTREE \((session.worktreeName ?? "").uppercased())?",
                        message: "Branch \(session.branch ?? "") is merged. The worktree and the branch are deleted, the session closes.",
                        action: "REMOVE"
                    ) { store.removeWorktree(of: session.id!) }
                }
                .buttonStyle(PixelButtonStyle())
                .overlay { Capsule().strokeBorder(Tokens.work, lineWidth: 1.5) }
                .help("The branch is merged: delete the worktree and its branch, close this session")
            }
            if store.dirtyProjectIds.contains(session.projectId) {
                Text("✎ UNCOMMITTED")
                    .font(Fonts.title(16))
                    .foregroundStyle(Tokens.warn)
                    .help("The project has uncommitted changes")
            }
            if store.canStartImplementation(session) {
                Button("PLAN → CODE") { isHandoffShown = true }
                    .buttonStyle(PixelButtonStyle())
                    .popover(isPresented: $isHandoffShown, arrowEdge: .top) {
                        HandoffNotes(notes: $handoffNotes) {
                            isHandoffShown = false
                            try? store.startImplementation(from: session.id!,
                                                           notes: handoffNotes.trimmingCharacters(in: .whitespacesAndNewlines))
                            handoffNotes = ""
                        }
                    }
                    .help("New session on the code stage's model with this plan as its first message")
            }
            if let fraction = store.contextFraction(for: session.id!), fraction >= store.relayThreshold {
                Button("RELAY") { store.relay(session.id!) }
                    .buttonStyle(PixelButtonStyle())
                    .overlay { Capsule().strokeBorder(Tokens.warn, lineWidth: 1.5) }
                    .disabled(store.relayingSessionIds.contains(session.id!))
                    .help("Context \(Int(fraction * 100))%: sync, then continue in a fresh session")
            }
        }
    }

    /// A click runs the stage's command right away; ship first checks that QA ran after the last edit.
    private func run(_ stage: Stage, checked: Bool = false) {
        if stage.name == "ship", !checked, store.codeChangedSinceQA(session.id!) {
            let qa = store.stages.first { $0.name == "qa" }
            store.confirmation = PixelConfirmation(
                title: "CODE CHANGED AFTER THE LAST QA",
                message: "Ship what QA hasn't seen, or run QA first?",
                action: "SHIP ANYWAY",
                alternative: qa.map { qa in ("RUN QA FIRST", { run(qa, checked: true) }) }
            ) { run(stage, checked: true) }
            return
        }
        if stage.command == "plan" {
            isPlanAsked = true // ask what to plan, so /plan starts with the task
        } else if let command = store.command(for: stage, in: session.projectId) {
            execute(command)
        } else {
            focusTerminal()
        }
    }

    private func help(for stage: Stage) -> String {
        guard let own = stage.command else { return "Code: talk to Claude" }
        guard let command = store.command(for: stage, in: session.projectId) else { return "/\(own) — not in this project" }
        if command != own { return "/\(command) — built into Claude Code (this project has no /\(own))" }
        if store.shadowsBuiltIn(stage, in: session.projectId) { return "/\(own) — your command, used instead of Claude Code's built-in /\(own)" }
        return "/\(own)"
    }

    private func execute(_ command: String) {
        store.type("/\(command)\r", into: session.id!)
        focusTerminal()
    }

    private func focusTerminal() {
        if let terminal = store.terminalView(for: session.id!) { terminal.window?.makeFirstResponder(terminal) }
    }
}

/// Pixel list of the project's other commands (a system menu stretches to the longest description).
private struct CommandList: View {
    let commands: [SlashCommand]
    let onPick: (SlashCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(commands) { command in
                    CommandRow(command: command) { onPick(command) }
                }
            }
            .padding(6)
        }
        .frame(width: 240)
        .frame(maxHeight: 380)
        .background(Tokens.dirt)
        .preferredColorScheme(.light)
    }
}

private struct CommandRow: View {
    let command: SlashCommand
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            // Names only: descriptions come from the user's own command files, in their language.
            Text("/\(command.name)").font(Fonts.mono(13)).foregroundStyle(Tokens.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(isHovered ? Tokens.grassLight : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// "What to plan?" — Enter sends `/plan <task>`; empty sends plain `/plan`.
private struct TaskPrompt: View {
    @Binding var task: String
    let onSubmit: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT TO PLAN?").font(Fonts.title(16)).foregroundStyle(Tokens.text)
            TextField("", text: $task)
                .textFieldStyle(.plain)
                .font(Fonts.mono(13))
                .foregroundStyle(Tokens.text)
                .padding(6)
                .background(Tokens.terminalBg)
                .sunken()
                .focused($focused)
                .onSubmit { onSubmit(task.trimmingCharacters(in: .whitespacesAndNewlines)) }
            Text("Enter to start · Esc to cancel").font(.caption).foregroundStyle(Tokens.textDim)
        }
        .padding(10)
        .frame(width: 360)
        .background(Tokens.grass)
        .preferredColorScheme(.light)
        .onAppear { focused = true }
    }
}

/// "No /plan in this project" — the user decides where the command should come from.
private struct MissingCommand: View {
    @Environment(AppStore.self) private var store
    let stage: Stage
    let session: Session
    let onDone: () -> Void

    var body: some View {
        let command = stage.command ?? stage.name
        let project = store.projects.first { $0.id == session.projectId }
        let sources = store.commandSources(command, excluding: session.projectId)
        VStack(alignment: .leading, spacing: 8) {
            Text("NO /\(command.uppercased())").font(Fonts.title(16)).foregroundStyle(Tokens.text)
            Text("\(project?.name ?? "This project") has no /\(command) command.")
                .font(.caption).foregroundStyle(Tokens.textDim)
            if sources.isEmpty {
                Text("No other project has it, and Claude Code has no built-in for it. Add .claude/commands/\(command).md, or remove the stage in Settings (⌘,).")
                    .font(.caption).foregroundStyle(Tokens.textDim)
            }
            ForEach(sources) { source in
                HStack {
                    Text("From \(source.name):").font(.caption).foregroundStyle(Tokens.text)
                    Spacer()
                    Button("THIS PROJECT") { store.copyCommand(command, from: source, toProject: project); onDone() }
                        .help("Copy to \(project?.name ?? "")/.claude/commands")
                    Button("ALL PROJECTS") { store.copyCommand(command, from: source, toProject: nil); onDone() }
                        .help("Copy to ~/.claude/commands — available in every project, VS Code too")
                }
                .buttonStyle(PixelButtonStyle())
            }
        }
        .padding(10)
        .frame(width: 440, alignment: .leading)
        .background(Tokens.grass)
        .preferredColorScheme(.light)
    }
}

/// Before plan → code: answers to the plan's open questions travel with the plan.
private struct HandoffNotes: View {
    @Binding var notes: String
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOTES FOR CODE").font(Fonts.title(16)).foregroundStyle(Tokens.text)
            Text("Answers to the plan's questions or extra instructions (optional).")
                .font(.caption).foregroundStyle(Tokens.textDim)
            TextEditor(text: $notes)
                .font(Fonts.mono(13))
                .foregroundStyle(Tokens.text)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 100)
                .background(Tokens.terminalBg)
                .sunken()
            HStack {
                Spacer()
                Button("START CODE", action: onStart)
                    .buttonStyle(PixelButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("⌘↩")
            }
        }
        .padding(10)
        .frame(width: 420)
        .background(Tokens.grass)
        .preferredColorScheme(.light)
    }
}
