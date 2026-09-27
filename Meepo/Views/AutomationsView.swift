import SwiftUI

/// Automations: the user's skills and commands, how often they're really used, and the knobs Claude Code has
/// for them — effort and model (personal skills), whether Claude may start one itself, and folding away
/// what hasn't been used for a month so it stops costing context every turn.
struct AutomationsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Automations.Item]?
    @State private var overrides: [String: String] = [:]
    @State private var error: String?
    @State private var measures: [String: (before: Double, after: Double?)] = [:]
    @State private var isNewWorkflow = false
    /// Checks after every answer — for every project, then this project's own; read in `reload`, not per render.
    @State private var checks: [(id: String, check: String, project: Project?)] = []

    private static let efforts = ["", "low", "medium", "high", "xhigh", "max"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your automations").font(Fonts.title(26))
                Spacer()
                Button("New workflow…") { isNewWorkflow = true }.buttonStyle(PixelButtonStyle(isPrimary: true))
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
            }
            Text("Skills and commands you have, counted from your own Claude Code history — every session, in meepo or not. Settings are yours: effort and model go into your own skill files; the rest into your ~/.claude/settings.json, so team files stay untouched.")
                .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(Tokens.danger) }
            if let items {
                let active = items.filter { !Automations.isFading($0) }
                let fading = items.filter { Automations.isFading($0) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !store.visibleSuggestions.isEmpty {
                            section("MEEPO NOTICED")
                            ForEach(store.visibleSuggestions) { NoticedRow(suggestion: $0) }
                        }
                        workflowsSection
                        section("DID MEEPO HELP?")
                        ForEach(Noticing.meepoReplacements, id: \.command) { measureRow($0) }
                        section("SKILLS AND COMMANDS")
                        header
                        ForEach(active) { row($0) }
                        if !fading.isEmpty {
                            Text("FADING OUT — NOT USED FOR 30 DAYS").font(Fonts.ui(11, weight: .bold)).tracking(1.2)
                                .foregroundStyle(Tokens.textDim).padding(.top, 18)
                            Text("Each one's description is read into every conversation. Folding it keeps the name (so /\u{2060}name still works) and saves that context.")
                                .font(.caption).foregroundStyle(Tokens.textDim)
                            ForEach(fading) { fadingRow($0) }
                        }
                    }
                }
            } else {
                Text("Reading your history…").foregroundStyle(Tokens.textDim)
                Spacer()
            }
        }
        .padding(22)
        .frame(width: 980, height: 680)
        .paperSheet()
        .task { await reload() }
        .sheet(isPresented: $isNewWorkflow, onDismiss: { Task { await reload() } }) { WorkflowSheet(project: project) }
    }

    private var project: Project? { store.selectedSession.flatMap(store.project(for:)) }

    /// Buttons, checks and Claude Code's saved workflows — what New workflow… made, and what's there already.
    @ViewBuilder
    private var workflowsSection: some View {
        let saved = project.flatMap { store.workflowsByProject[$0.id!] } ?? []
        HStack(alignment: .firstTextBaseline) {
            section("YOUR WORKFLOWS")
            InfoButton(title: "Workflows", text: Explain.workflows)
        }
        if store.skillButtons.isEmpty && checks.isEmpty && saved.isEmpty {
            Text("None yet. New workflow… makes a button that runs steps in order, or a check after every answer.")
                .foregroundStyle(Tokens.textDim)
        }
        ForEach(store.skillButtons, id: \.self) { name in
            workflowRow("/" + name, "Button · a skill of yours") { store.removeButton(name) }
        }
        ForEach(checks, id: \.id) { _, check, project in
            workflowRow(check, "After every answer · " + (project.map { "only \($0.name)" } ?? "all projects")) {
                apply { try store.removeCheck(check, in: project) }
            }
        }
        ForEach(saved) { workflow in
            workflowRow(workflow.name, "Saved workflow · Claude Code" + (workflow.description.map { " · " + $0 } ?? ""), remove: nil)
        }
    }

    private func workflowRow(_ title: String, _ detail: String, remove: (() -> Void)?) -> some View {
        HStack {
            Text(title).font(Fonts.mono(13).weight(.semibold)).lineLimit(1)
            Text(detail).foregroundStyle(Tokens.textDim).lineLimit(1)
            Spacer()
            if let remove { Button("Remove", action: remove).buttonStyle(PixelButtonStyle(compact: true)) }
        }
        .padding(12)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func section(_ title: String) -> some View {
        Text(title).font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.textDim).padding(.top, 14)
    }

    /// A change in Meepo against the user's real behavior: how often they still reach for the old way.
    private func measureRow(_ item: (command: String, feature: String, since: Date)) -> some View {
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.feature).font(Fonts.ui(14, weight: .semibold))
                Text(Self.measureText(item.command, measures[item.command])).font(.caption).foregroundStyle(Tokens.textDim)
            }
            Spacer()
        }
        .padding(12)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    /// "You typed /usage 11× a week before, 3× a week since." Plain statements: one long `+` chain of optionals
    /// was too much for the release compiler.
    static func measureText(_ command: String, _ rate: (before: Double, after: Double?)?) -> String {
        guard let rate else { return "You typed /\(command) …" }
        let before = String(format: "You typed /%@ %.0f× a week before", command, rate.before)
        guard let after = rate.after else { return before + " — measuring, check back after a week." }
        return before + String(format: ", %.0f× a week since.", after)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("AUTOMATION").frame(width: 220, alignment: .leading)
            Text("LAST 8 WEEKS").frame(width: 150, alignment: .leading)
            Text("EFFORT").frame(width: 110, alignment: .leading)
            Text("MODEL").frame(width: 110, alignment: .leading)
            Text("CLAUDE MAY START IT").frame(width: 170, alignment: .leading)
        }
        .font(Fonts.ui(11, weight: .bold)).tracking(1).foregroundStyle(Tokens.textDim)
        .padding(.horizontal, 14)
    }

    private func row(_ item: Automations.Item) -> some View {
        HStack(spacing: 12) {
            nameCell(item).frame(width: 220, alignment: .leading)
            HStack(spacing: 8) {
                Sparkline(values: item.usage.weekly)
                Text("\(item.usage.total)").font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
            }
            .frame(width: 150, alignment: .leading)
            frontmatterMenu(item, key: "effort", value: item.effort, options: Self.efforts.map { ($0, $0.isEmpty ? "Default" : $0) })
                .frame(width: 110, alignment: .leading)
            frontmatterMenu(item, key: "model", value: item.model, options: store.modelChoices())
                .frame(width: 110, alignment: .leading)
            mayStartToggle(item).frame(width: 170, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Tokens.line))
    }

    private func nameCell(_ item: Automations.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("/" + item.name).font(Fonts.mono(13).weight(.semibold)).lineLimit(1)
            Text([item.owner.rawValue, item.projects.isEmpty ? nil : item.projects.count > 3
                  ? "\(item.projects.count) projects" : item.projects.joined(separator: ", ")]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(Tokens.textDim).lineLimit(1)
        }
        .help(item.description ?? item.name)
    }

    @ViewBuilder
    private func frontmatterMenu(_ item: Automations.Item, key: String, value: String?, options: [(value: String, title: String)]) -> some View {
        if item.canEdit {
            PixelMenu(selection: value ?? "Default") {
                ForEach(options, id: \.value) { option in
                    Button(option.title) { apply { try store.setFrontmatter(item, key, to: option.value.isEmpty ? nil : option.value) } }
                }
            }
            .help((key == "model" ? "Switching model mid-conversation drops the prompt cache for that turn" : "Claude Code uses this effort while the skill runs")
                  + (item.personalFiles.count > 1 ? ". Set on all \(item.personalFiles.count) of your copies" : "")
                  + (item.teamFiles.isEmpty ? "" : "; the team's copy in git stays as it is"))
        } else {
            Text(value ?? "—").foregroundStyle(Tokens.textDim)
                .help(item.owner == .team ? "A team file under git — change it in the repo, for everyone" : "Built into Claude Code")
        }
    }

    @ViewBuilder
    private func mayStartToggle(_ item: Automations.Item) -> some View {
        let manualOnly = overrides[item.name] == "user-invocable-only"
        if item.isUserOnly {
            // disable-model-invocation in the file (or a Claude Code screen): a switch in settings can't turn it on.
            Text(item.owner == .builtIn ? "Only you" : "Only you (set in its file)").foregroundStyle(Tokens.work)
                .fixedSize(horizontal: false, vertical: true)
                .help("Only you start /\(item.name). Claude can't — so a workflow that uses it as a step stops there.")
        } else {
            Toggle(isOn: Binding(
                get: { !manualOnly },
                set: { on in apply { try store.setSkillOverride(item.name, to: on ? "on" : "user-invocable-only") } }
            )) {
                Text(manualOnly ? "Only you" : "Yes").foregroundStyle(manualOnly ? Tokens.work : Tokens.textDim)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help((manualOnly ? "Only you start it with /\(item.name)." : "Claude may run it by itself when it fits the task.")
                  + " Off: a workflow that uses it as a step stops there.")
        }
    }

    private func fadingRow(_ item: Automations.Item) -> some View {
        let folded = overrides[item.name] == "name-only"
        return HStack(spacing: 12) {
            nameCell(item).frame(width: 220, alignment: .leading)
            Text(item.usage.lastUsed.map { "last used \($0.formatted(.relative(presentation: .named)))" } ?? "not used since your history starts")
                .foregroundStyle(Tokens.textDim)
            Spacer()
            if folded {
                Text("Folded").foregroundStyle(Tokens.work)
                Button("Unfold") { apply { try store.setSkillOverride(item.name, to: "on") } }
                    .buttonStyle(PixelButtonStyle(compact: true))
            } else {
                Button("Fold description") { apply { try store.setSkillOverride(item.name, to: "name-only") } }
                    .buttonStyle(PixelButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func apply(_ change: () throws -> Void) {
        do {
            try change()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        Task { await reload() }
    }

    private func reload() async {
        checks = store.checks(in: nil).map { (id: $0, check: $0, project: nil as Project?) }
            + (project.map { p in store.checks(in: p).map { (id: p.path + $0, check: $0, project: p as Project?) } } ?? [])
        overrides = store.skillOverrides()
        items = await store.automations()
        await store.refreshSuggestions()
        measures = await Task.detached {
            let text = (try? String(contentsOf: Automations.historyFile, encoding: .utf8)) ?? ""
            let entries = Noticing.entries(historyLines: text.split(separator: "\n"))
            return Dictionary(uniqueKeysWithValues: Noticing.meepoReplacements.map { ($0.command, Noticing.rate(of: $0.command, in: entries, around: $0.since)) })
        }.value
    }
}

/// Eight weekly bars, the current week last.
private struct Sparkline: View {
    let values: [Int]

    var body: some View {
        let top = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(values.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(values[i] == 0 ? Tokens.line : Tokens.work.opacity(0.35 + 0.65 * Double(values[i]) / Double(top)))
                    .frame(width: 9, height: max(3, 22 * CGFloat(values[i]) / CGFloat(top)))
            }
        }
        .frame(height: 22, alignment: .bottom)
        .help(values.map(String.init).joined(separator: " · "))
    }
}
