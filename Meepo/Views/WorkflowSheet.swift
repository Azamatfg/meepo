import SwiftUI

/// The workflow constructor: when → what → where. It shows the Claude Code file it will write and writes nothing
/// until Save; the file works in any terminal, and ≡ → Tools → Changes undoes it.
struct WorkflowSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The project the sheet was opened for; nil: no project selected, so checks go to every project.
    let project: Project?

    enum When: String, CaseIterable { case button = "When I press its button", afterAnswer = "After every answer Claude gives" }

    @State private var when = When.button
    @State private var name = ""
    @State private var steps: [Recipes.Step] = []
    @State private var words = ""
    @State private var check = ""
    @State private var everyProject = false
    @State private var error: String?
    @State private var isNewCommand = false
    /// skillOverrides from ~/.claude/settings.json, read once: "only you" there keeps a command out of the steps.
    @State private var overrides: [String: String] = [:]

    private var suggestedName: String { Recipes.suggestedName(for: steps) }
    private var slug: String { ClaudeLauncher.worktreeSlug(name.isEmpty ? suggestedName : name) }
    private var trimmedCheck: String { check.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
    private var checkProject: Project? { everyProject ? nil : project }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("New workflow").font(Fonts.title(26))
                Spacer()
                InfoButton(title: "Workflows", text: Explain.workflows)
            }
            Text("meepo writes it as a plain Claude Code file: it works in any terminal too, and ≡ → Tools → Changes undoes it.")
                .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            Picker("When", selection: $when) {
                ForEach(When.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch when {
            case .button: buttonForm
            case .afterAnswer: checkForm
            }
            Text("PREVIEW — " + target).font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.textDim)
                .lineLimit(1).truncationMode(.head)
            ScrollView {
                Text(preview).font(Fonts.mono(12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 10))
            if let error { Text(error).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PixelButtonStyle(isPrimary: true))
                    .disabled(when == .button ? steps.isEmpty || Recipes.nameProblem(slug, taken: []) != nil : trimmedCheck.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 720, height: 640)
        .paperSheet()
        .onAppear { overrides = store.skillOverrides() }
        .sheet(isPresented: $isNewCommand) { NewCommandSheet { steps.append(.command($0)) } }
    }

    private var buttonForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Name").foregroundStyle(Tokens.textDim)
                TextField(suggestedName.isEmpty ? "tidy-and-ship" : suggestedName, text: $name)
                    .textFieldStyle(.roundedBorder).frame(width: 240)
                Text("→ /\(slug)").font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
            }
            // Only Claude Code's own names here: one of yours may be this very button, removed earlier — Save pins it again.
            if !slug.isEmpty, let problem = Recipes.nameProblem(slug, taken: []) {
                Text(problem).font(.caption).foregroundStyle(Tokens.danger)
            } else {
                let shown = "/" + (slug.isEmpty ? "tidy-and-ship" : slug)
                Text("Saving makes \(shown) — a command of yours in every project: its button appears next to the stages, and \(shown) works in any terminal too.")
                    .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 8) {
                    Text("\(index + 1).").font(Fonts.mono(13)).foregroundStyle(Tokens.textDim)
                    Text(step.line).font(Fonts.mono(13)).lineLimit(2)
                    Spacer()
                    Button("↑") { steps.swapAt(index, index - 1) }.buttonStyle(PixelButtonStyle(compact: true)).disabled(index == 0)
                    Button("↓") { steps.swapAt(index, index + 1) }.buttonStyle(PixelButtonStyle(compact: true))
                        .disabled(index == steps.count - 1)
                    Button("Remove") { steps.remove(at: index) }.buttonStyle(PixelButtonStyle(compact: true))
                }
            }
            HStack(spacing: 8) {
                PixelMenu(selection: "Add a command") {
                    Button("New command…") { isNewCommand = true }
                    Divider()
                    ForEach(commands) { command in
                        Button("/" + command.name) { steps.append(.command(command.name)) }
                    }
                }
                .help("Commands Claude can start. Ones only you start (like Claude Code's /plan) aren't here: a workflow would stop at them.")
                TextField("…or tell Claude what to do", text: $words).textFieldStyle(.roundedBorder)
                    .onSubmit(addWords)
                Button("Add") { addWords() }.buttonStyle(PixelButtonStyle(compact: true))
                    .disabled(words.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("A step is a command or plain words for Claude. Each starts when the one before has finished; Claude stops if a step asks you something or fails. Right-click the button to repeat it or schedule it in the cloud.")
                .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checkForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Check").foregroundStyle(Tokens.textDim)
                TextField("npm test", text: $check).textFieldStyle(.roundedBorder).font(Fonts.mono(13))
            }
            if project != nil {
                Picker("Where", selection: $everyProject) {
                    Text("Only \(project!.name), only for me").tag(false)
                    Text("All my projects").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
            Text("Runs whenever Claude finishes an answer and there are uncommitted changes. If it fails, Claude reads the output and fixes it before finishing.")
                .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var commands: [SlashCommand] {
        Recipes.stepChoices(project.flatMap { store.commandsByProject[$0.id!] } ?? CommandCatalog.builtIns,
                            buttons: store.skillButtons, overrides: overrides)
    }

    private var target: String {
        switch when {
        case .button: "~/.claude/skills/\(slug.isEmpty ? "…" : slug)/SKILL.md"
        case .afterAnswer: checkProject.map { $0.path + "/.claude/settings.local.json" } ?? "~/.claude/settings.json"
        }
    }

    private var preview: String {
        switch when {
        case .button: Recipes.skill(name: slug, steps: steps)
        case .afterAnswer: Recipes.settingsText(Recipes.addingCheck(trimmedCheck.isEmpty ? "npm test" : trimmedCheck, to: [:]))
        }
    }

    private func addWords() {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        steps.append(.prompt(text))
        words = ""
    }

    private func save() {
        do {
            switch when {
            case .button: try store.makeButton(named: slug, steps: steps)
            case .afterAnswer: try store.addCheck(trimmedCheck, in: checkProject)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// "New command…" in the step menu: a name and what Claude should do. Saved as a skill of the user's that Claude may
/// start too — that's what lets it be a step — logged in Tools → Changes, and added as the next step right away.
private struct NewCommandSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onSaved: (String) -> Void
    @State private var name = ""
    @State private var instructions = ""
    @State private var error: String?

    private var slug: String { ClaudeLauncher.worktreeSlug(name) }

    var body: some View {
        let problem = Recipes.nameProblem(slug, taken: store.commandNames)
        VStack(alignment: .leading, spacing: 12) {
            Text("New command").font(Fonts.title(24))
            HStack {
                Text("Name").foregroundStyle(Tokens.textDim)
                TextField("check-staging", text: $name).textFieldStyle(.roundedBorder).frame(width: 240)
                Text("→ /\(slug.isEmpty ? "…" : slug)").font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
            }
            if let problem, !slug.isEmpty {
                Text(problem).font(.caption).foregroundStyle(Tokens.danger)
            } else {
                Text("Saving makes /\(slug.isEmpty ? "check-staging" : slug) — a command of yours in every project and any terminal. Claude may start it too when it fits, which is what lets it be a step. Undo it in ≡ → Tools → Changes.")
                    .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            }
            Text("What should Claude do when you run it?").foregroundStyle(Tokens.textDim)
            TextEditor(text: $instructions)
                .font(Fonts.mono(12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 10))
            Text("Say it as you'd say it to Claude: “Open the staging site, check the login and checkout, tell me what broke.” Not sure how to put it? Ask Claude in a session: “make me a /name command that …”. For bigger ones, with checks and examples, Claude Code's skill-creator helps: /plugin install skill-creator@claude-plugins-official.")
                .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let error { Text(error).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
                Button("Save") {
                    do {
                        onSaved(try store.makeCommand(named: slug, instructions: instructions))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PixelButtonStyle(isPrimary: true))
                .disabled(problem != nil || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 600, height: 520)
        .paperSheet()
    }
}
