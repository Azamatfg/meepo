import SwiftUI

/// Command bar under the terminal (SPEC module 4, design §5): the workflow stages as pixel buttons —
/// plus the project's other commands, "To code" and "Relay".
struct StagePanel: View {
    @Environment(AppStore.self) private var store
    let session: Session
    @State private var isMoreShown = false
    @State private var isPlanAsked = false
    @State private var missingStage: Stage?
    @State private var isHandoffShown = false
    @State private var handoffNotes = ""
    @State private var planTask = ""
    /// The button whose "Schedule in the cloud…" is open.
    @State private var scheduling: String?
    @State private var scheduleWhen = ""
    @State private var buttonError: String?
    @State private var isStagesEdited = false
    /// How to use voice, shown once: the first time it's turned on.
    @State private var isVoiceHintShown = false
    @State private var isDrawAsked = false
    @State private var drawing: Diagram.Request?

    var body: some View {
        // Scrolls sideways when the window is narrow. Not ViewThatFits: on macOS 15 it measures its options on
        // SwiftUI's DisplayLink thread, building this row's ForEach there — a main-actor closure — which trapped
        // on every Option+Tab (the tester's crash, 2026-09-25).
        ScrollView(.horizontal, showsIndicators: false) { row }
            .padding(6)
            .background(Tokens.frameMid)
            .sheet(isPresented: $isStagesEdited) { StagesSheet() }
    }

    /// Stages, then session tools.
    @ViewBuilder
    private var row: some View {
        // All stages are always shown; ones this project lacks are dimmed and offer to add the command.
        let stages = store.stages
        let available = Set(store.stages(for: session.projectId).map(\.name))
        // One button lit: what to press now (none while Claude works or nothing's waiting).
        let next = Stage.nextStep(after: session.stage, isReady: store.look(of: session).ring == .idle,
                                  hasUncommitted: store.dirtyProjectIds.contains(session.projectId),
                                  bar: stages.filter { available.contains($0.name) }.map(\.name))
        HStack(spacing: 6) {
            InfoButton(title: "Stages", text: Explain.stages)
            ForEach(stages) { stage in
                Button(stage.label) { available.contains(stage.name) ? run(stage) : (missingStage = stage) }
                    .buttonStyle(PixelButtonStyle(isPrimary: stage.name == next))
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
                    .contextMenu {
                        Button("Hide \(stage.label) from this bar") { store.stages.removeAll { $0.id == stage.id } }
                        Button("Edit stages…") { isStagesEdited = true }
                    }
                    .help(stage.name == next ? "Next step · " + help(for: stage) : help(for: stage))
            }
            ForEach(store.skillButtons(for: session.projectId), id: \.self) { name in
                Button("/" + name) {
                    store.type("/\(name)\r", into: session.id!)
                    store.count("button." + name)
                }
                    .buttonStyle(PixelButtonStyle())
                    .overlay { Capsule().strokeBorder(Tokens.work.opacity(0.5), lineWidth: 1) }
                    .help("Your workflow /\(name): runs its steps in order. Right-click to repeat or schedule it.")
                    .contextMenu {
                        Menu("Repeat while this session is open") {
                            ForEach([10, 30, 60, 120], id: \.self) { minutes in
                                Button(minutes < 60 ? "Every \(minutes) minutes" : "Every \(minutes / 60) hour\(minutes > 60 ? "s" : "")") {
                                    store.repeatButton(name, every: minutes, in: session.id!)
                                }
                            }
                        }
                        Button("Schedule in the cloud…") {
                            buttonError = nil
                            scheduling = name
                        }
                        Divider()
                        Button("Remove button") { store.removeButton(name) }
                    }
                    .popover(isPresented: Binding(get: { scheduling == name }, set: { if !$0 { scheduling = nil } }), arrowEdge: .top) {
                        SchedulePrompt(when: $scheduleWhen, error: buttonError) { when in
                            do {
                                try store.scheduleButton(name, when: when, in: session.id!)
                                scheduling = nil
                                buttonError = nil
                            } catch { buttonError = error.localizedDescription }
                        }
                    }
            }
            if let workflows = store.workflowsByProject[session.projectId], !workflows.isEmpty {
                PixelMenu(selection: "WORKFLOWS") {
                    ForEach(workflows) { workflow in
                        Button(workflow.name) { store.runWorkflow(workflow, in: session.id!) }
                    }
                }
                .help("Claude Code's saved workflows: several agents at once. Pick one to run it in this session.")
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
                            store.count("more." + command.name)
                        } pin: { command in
                            isMoreShown = false
                            store.pinCommand(command.name)
                        }
                    }
            }
            Spacer()
            Button(store.drawingSessionIds.contains(session.id!) ? "DRAWING…" : "DRAW") { isDrawAsked = true }
                .buttonStyle(PixelButtonStyle())
                .help("A picture instead of text: Claude's last answer, what changed, or how something works")
                .popover(isPresented: $isDrawAsked, arrowEdge: .top) {
                    DrawPrompt { request in
                        isDrawAsked = false
                        drawing = request
                    }
                }
                .sheet(item: $drawing) { DiagramSheet(sessionId: session.id!, request: $0) }
            Button("PHONE") { store.type("/remote-control\r", into: session.id!) }
                .buttonStyle(PixelButtonStyle())
                .help("Turn on Claude Code Remote Control: follow and answer this session from the Claude app or claude.ai")
            // Needs a Claude.ai sign-in; with an API key or a cloud provider Claude Code has no voice.
            if Voice.isAvailable(authMethod: store.claudeAuthMethod) {
                let listening = store.listeningSessionIds.contains(session.id!)
                Button(!store.isVoiceOn ? "VOICE" : listening ? "■ STOP" : "SPEAK") {
                    if store.isVoiceOn {
                        store.speak(in: session.id!)
                    } else {
                        Task { if await store.toggleVoice() { isVoiceHintShown = true } }
                    }
                }
                .buttonStyle(PixelButtonStyle(isPrimary: listening))
                .overlay { if store.isVoiceOn && !listening { Capsule().strokeBorder(Tokens.work, lineWidth: 1.5).allowsHitTesting(false) } }
                .help(!store.isVoiceOn
                      ? "Talk instead of typing: turns on Claude Code's voice dictation (/voice) in every session. The first time, macOS asks whether meepo may use the microphone."
                      : listening
                      ? "Listening. Click STOP when you're done — the words go into the prompt, not sent yet."
                      : "Click SPEAK and talk, STOP when done: the words land in the prompt, unsent — fix them, SPEAK again to add more, SEND when it's right. Holding Space in the terminal does the same. Right-click to turn voice off.")
                .contextMenu {
                    if store.isVoiceOn {
                        Button("Turn voice off") { Task { _ = await store.toggleVoice() } }
                    }
                }
                .popover(isPresented: $isVoiceHintShown, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Voice is on").font(Fonts.ui(14, weight: .bold))
                        Text("Click SPEAK and talk, STOP when you're done — the words go into the prompt, not sent. Fix them, SPEAK again to add more, then SEND. Holding Space in a terminal does the same. It's Claude Code's /voice: it works in every session, in meepo and outside it; the language is in /config.")
                            .font(Fonts.ui(13)).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(width: 320, alignment: .leading)
                    .paperSheet()
                }
                if store.isVoiceOn {
                    Button("SEND") { store.sendSpoken(in: session.id!) }
                        .buttonStyle(PixelButtonStyle())
                        .disabled(listening)
                        .help(listening
                              ? "STOP first: the words land in the prompt a moment after, then SEND sends them"
                              : "Enter: sends what's in the prompt — what you said, and any fixes — to Claude")
                }
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
            if store.triesInARow(session) >= 3, store.look(of: session).ring == .idle {
                Button("FRESH START") { store.relay(session.id!) }
                    .buttonStyle(PixelButtonStyle())
                    .overlay { Capsule().strokeBorder(Tokens.warn, lineWidth: 1.5) }
                    .disabled(store.relayingSessionIds.contains(session.id!))
                    .help("\(store.triesInARow(session)) tries in a row on the same files. After two corrections a fresh session usually does better: Claude writes down what was learned, and a new session starts with it")
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
        if !checked { store.count("stage." + stage.name) }
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
    /// Right-click → Pin to the bar: the command becomes a button next to the stages.
    var pin: ((SlashCommand) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(commands) { command in
                    CommandRow(command: command) { onPick(command) }
                        .contextMenu { if let pin { Button("Pin /\(command.name) to the bar") { pin(command) } } }
                }
            }
            .padding(6)
        }
        .frame(width: 240)
        .frame(maxHeight: 380)
        .background(Tokens.dirt)
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

/// When a button's cloud routine runs, in the user's words — Claude Code's /schedule asks for the rest.
private struct SchedulePrompt: View {
    @Binding var when: String
    let error: String?
    let onSubmit: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHEN SHOULD IT RUN?").font(Fonts.title(16))
            TextField("every weekday at 9am", text: $when)
                .textFieldStyle(.roundedBorder)
                .font(Fonts.mono(13))
                .focused($focused)
                .onSubmit { if !when.trimmingCharacters(in: .whitespaces).isEmpty { onSubmit(when) } }
            Text("Claude Code's /schedule makes a routine on claude.ai that runs in the cloud on this repo — even with your Mac off. It needs GitHub connected there; your own skills aren't in the cloud, so the steps are sent written out.")
                .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(Tokens.danger) }
        }
        .padding(12)
        .frame(width: 380)
        .paperSheet()
        .onAppear { focused = true }
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
        .onAppear { focused = true }
    }
}

/// "No /plan in this project" — the user decides where the command should come from.
private struct MissingCommand: View {
    @Environment(AppStore.self) private var store
    let stage: Stage
    let session: Session
    let onDone: () -> Void
    /// Per source project, the projects whose own /command its copy would replace — read once, off the body
    /// (it compares files); a source not read yet offers no ALL PROJECTS.
    @State private var replacedBySource: [Int64: [String]] = [:]

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
                // Claude Code runs your ~/.claude copy before a project's own: ALL PROJECTS would quietly replace theirs.
                let replaced = replacedBySource[source.id ?? -1]
                HStack {
                    Text("From \(source.name):").font(.caption).foregroundStyle(Tokens.text)
                    Spacer()
                    Button("THIS PROJECT") { store.copyCommand(command, from: source, toProject: project); onDone() }
                        .help("Copy to \(project?.name ?? "")/.claude/commands")
                    if replaced?.isEmpty == true {
                        Button("ALL PROJECTS") { store.copyCommand(command, from: source, toProject: nil); onDone() }
                            .help("Copy to ~/.claude/commands — available in every project, VS Code too")
                    }
                }
                .buttonStyle(PixelButtonStyle())
                if let replaced, !replaced.isEmpty {
                    let (owners, theirs) = replaced.count == 1 ? ("\(replaced[0]) has its", "it") : ("\(replaced.joined(separator: ", ")) have their", "theirs")
                    Text("Not for all projects: \(owners) own /\(command). A copy for all projects would run instead of \(theirs) — Claude Code picks your ~/.claude copy first.")
                        .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(width: 440, alignment: .leading)
        .background(Tokens.grass)
        .task {
            let command = stage.command ?? stage.name
            for source in store.commandSources(command, excluding: session.projectId) {
                replacedBySource[source.id ?? -1] = store.projectsReplaced(byCopyOf: command, from: source, excluding: session.projectId).map(\.name)
            }
        }
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
    }
}

/// DRAW's three kinds of picture; a question is answered by Claude reading the code.
private struct DrawPrompt: View {
    let pick: (Diagram.Request) -> Void
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DRAW").font(Fonts.title(14))
            Button("Claude's last answer") { pick(.lastAnswer) }
                .help("The long answer above, as one picture")
            Button("What changed") { pick(.changes) }
                .help("What the uncommitted changes do, and where")
            Text("How does… work?").font(Fonts.ui(12, weight: .semibold)).padding(.top, 4)
            TextField("how a payment reaches the database", text: $question)
                .textFieldStyle(.roundedBorder).frame(width: 300)
                .onSubmit { if !question.trimmingCharacters(in: .whitespaces).isEmpty { pick(.question(question)) } }
            Text("Claude reads the code to draw it; it changes nothing.").font(.caption).foregroundStyle(Tokens.textDim)
        }
        .buttonStyle(PixelButtonStyle(compact: true))
        .padding(14)
    }
}

/// The picture: drawn once on open, with Redraw and the Mermaid source to copy.
struct DiagramSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sessionId: Int64
    let request: Diagram.Request
    @State private var result: Diagram.Result?
    @State private var error: String?
    private var isDrawing: Bool { store.drawingSessionIds.contains(sessionId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(result?.title ?? "Drawing…").font(Fonts.ui(18, weight: .bold)).lineLimit(1)
                Spacer()
                if let result {
                    Button("Copy Mermaid") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.mermaid, forType: .string)
                    }
                    .help("Paste into a README, a PR or mermaid.live")
                }
                Button("Redraw") { draw() }.disabled(isDrawing)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let caption = result?.caption {
                Text(caption).font(Fonts.ui(14)).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true) }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Tokens.surface)
                if let result {
                    MermaidView(text: result.mermaid).padding(4)
                } else if isDrawing {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Claude is drawing — about half a minute").font(.caption).foregroundStyle(Tokens.textDim)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("drag to move · pinch or ⌘-scroll to zoom").font(.caption2).foregroundStyle(Tokens.textDim).padding(8)
            }
        }
        .padding(18)
        .frame(minWidth: 900, minHeight: 620)
        .background(Tokens.grass)
        .buttonStyle(PixelButtonStyle(compact: true))
        .task { draw() }
    }

    private func draw() {
        error = nil
        Task {
            do { result = try await store.draw(request, for: sessionId) } catch { self.error = error.localizedDescription }
        }
    }
}
