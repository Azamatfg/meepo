import SwiftUI

/// The selected session's context window by part, as /context breaks it down, measured by the mod after each
/// answer: what fills it, which CLAUDE.md and memory files, what loaded on demand, skills and MCP — and what to do
/// about it (compact, clear, hand off to a fresh session).
struct ContextPanel: View {
    @Environment(AppStore.self) private var store
    /// CLAUDE.md files, rules and memory of the session's project, read off the main thread.
    @State private var sources: AppStore.SourcesSnapshot?
    /// Bumped after a change here (a new rule, a deleted memory) so the sources are read again.
    @State private var revision = 0
    @State private var isNewRuleShown = false
    @State private var ruleName = ""
    @State private var isAllMemoryShown = false

    var body: some View {
        if let session = store.selectedSession, let id = session.id {
            VStack(alignment: .leading, spacing: 10) {
                if let usage = store.contextUsage[id] {
                    summary(usage)
                    section("FILLS IT") { ForEach(usage.used, id: \.name) { row($0.name, $0.tokens, of: usage) } }
                    section("CLAUDE.md AND MEMORY") {
                        ForEach(usage.memoryFiles, id: \.path) { file in
                            fileRow(file.path, detail: file.type, tokens: file.tokens)
                        }
                    }
                    let onDemand = (store.loadedInstructions[id] ?? []).filter { $0.reason != "session_start" }
                    if !onDemand.isEmpty {
                        section("LOADED ON DEMAND") {
                            ForEach(onDemand, id: \.path) { fileRow($0.path, detail: Self.reason($0.reason), tokens: nil) }
                        }
                    }
                    if !usage.skills.isEmpty {
                        section("SKILLS · \(TokenFormat.short(usage.skills.reduce(0) { $0 + $1.tokens }))") {
                            ForEach(usage.skills.prefix(5), id: \.name) { row("/" + $0.name, $0.tokens, of: usage) }
                            if usage.skills.count > 5 { dim("+ \(usage.skills.count - 5) more") }
                        }
                    }
                    if !usage.mcp.isEmpty {
                        section("MCP SERVERS") { ForEach(usage.mcp, id: \.server) { row($0.server, $0.tokens, of: usage) } }
                    }
                } else {
                    dim("Measured after Claude's next answer in this session. A session started before this meepo version needs a restart.")
                }
                if let sources { sourcesSections(sources) }
                actions(id)
            }
            // Read again when the session, or what it measured and loaded, changes.
            .task(id: "\(id) \(store.contextUsage[id]?.tokens ?? 0) \(store.loadedInstructions[id]?.count ?? 0) \(revision)") {
                sources = await store.readSources(of: session)
            }
        } else {
            dim("Select a session to see its context.")
        }
    }

    private func summary(_ usage: ContextUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(usage.percent ?? 0)%").font(Fonts.ui(18, weight: .bold))
                    .foregroundStyle((usage.percent ?? 0) >= Int(store.relayThreshold * 100) ? Tokens.need : Tokens.text)
                Text("\(TokenFormat.short(usage.tokens ?? 0)) of \(TokenFormat.short(usage.window))").foregroundStyle(Tokens.textDim)
                Spacer()
            }
            bar(Double(usage.percent ?? 0) / 100)
            if let at = usage.autoCompactAt { dim("Claude Code compacts by itself at \(TokenFormat.short(at))") }
        }
    }

    private func actions(_ id: Int64) -> some View {
        HStack(spacing: 6) {
            Button("COMPACT") { store.type("/compact\r", into: id) }
                .help("/compact: Claude Code sums up the conversation and keeps going on the summary")
            Button("HAND OFF") { store.relay(id) }
                .help("Claude sums up the task, decisions and files; a fresh session carries on, this one closes")
            Button("CLEAR") {
                store.confirmation = PixelConfirmation(
                    title: "Clear this session's context?",
                    message: "/clear starts the conversation over in the same session. The old one stays in Claude Code (claude --resume).",
                    action: "Clear"
                ) { store.type("/clear\r", into: id) }
            }
            .help("/clear: start over with an empty context")
        }
        .buttonStyle(PixelButtonStyle(compact: true))
    }

    // MARK: Sources

    @ViewBuilder
    private func sourcesSections(_ sources: AppStore.SourcesSnapshot) -> some View {
        if !sources.hints.isEmpty {
            section("HINTS") {
                ForEach(sources.hints, id: \.text) { hint in
                    Button { if let path = hint.path { store.editor.open(path) } } label: {
                        Label(hint.text, systemImage: "lightbulb").font(Fonts.ui(12)).foregroundStyle(Tokens.text)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        let everyTurn = sources.instructions.filter { $0.loading == .always }.reduce(0) { $0 + $1.tokens }
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("SOURCES · ≈\(TokenFormat.short(everyTurn)) EVERY TURN").font(Fonts.ui(11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            ForEach(sources.instructions, id: \.path) { item in
                // A rule's name says which it is; a CLAUDE.md's folder does.
                fileRow(item.path, detail: "\(item.scope) · \(Self.loading(item))", tokens: item.tokens, isEstimate: !item.isMeasured,
                        showsPath: item.path.hasSuffix("CLAUDE.md") || item.path.hasSuffix("CLAUDE.local.md"))
            }
            HStack(spacing: 6) {
                Button("REMEMBER") { if let id = store.selectedSession?.id { _ = store.type(AppStore.rememberPrompt + "\r", into: id) } }
                    .help("Claude picks what from this conversation should outlast it — for CLAUDE.md, a rule or memory — and shows it before writing")
                Button("+ RULE") { ruleName = ""; isNewRuleShown = true }
                    .help("A rule in .claude/rules: loaded only when Claude reads the files its paths: name")
                    .popover(isPresented: $isNewRuleShown) { newRule(in: sources.folder) }
            }
            .buttonStyle(PixelButtonStyle(compact: true))
            .padding(.top, 3)
        }
        if let memory = sources.memory, !memory.entries.isEmpty {
            section("MEMORY · \(memory.entries.count)") {
                fileRow(memory.index, detail: "index · \(memory.indexLines) lines", tokens: nil)
                ForEach(isAllMemoryShown ? memory.entries : Array(memory.entries.prefix(6)), id: \.file) { entry in
                    memoryRow(entry, in: memory)
                }
                if memory.entries.count > 6 {
                    Button(isAllMemoryShown ? "Show fewer" : "Show all \(memory.entries.count)") { isAllMemoryShown.toggle() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Tokens.work)
                }
                if !memory.unwritten.isEmpty {
                    dim("Linked, not written yet: \(memory.unwritten.joined(separator: ", "))")
                }
            }
        }
    }

    private func newRule(in folder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New rule").font(Fonts.ui(13, weight: .semibold))
            TextField("What it's about, e.g. API handlers", text: $ruleName)
                .textFieldStyle(.roundedBorder).frame(width: 240)
                .onSubmit { createRule(in: folder) }
            Button("CREATE") { createRule(in: folder) }.buttonStyle(PixelButtonStyle(compact: true))
                .disabled(ClaudeLauncher.worktreeSlug(ruleName).isEmpty)
        }
        .padding(12)
    }

    private func createRule(in folder: String) {
        guard !ClaudeLauncher.worktreeSlug(ruleName).isEmpty else { return }
        store.newRule(named: ruleName, in: folder)
        isNewRuleShown = false
        revision += 1
    }

    private func memoryRow(_ entry: Sources.MemoryEntry, in memory: Sources.Memory) -> some View {
        Button { store.editor.open("\(memory.folder)/\(entry.file)") } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title).lineLimit(1).foregroundStyle(entry.exists ? Tokens.text : Tokens.textDim)
                Text(entry.hook.isEmpty ? entry.file : entry.hook).font(.caption).foregroundStyle(Tokens.textDim).lineLimit(1)
            }
            .font(Fonts.ui(13)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entry.exists)
        .contextMenu {
            Button("Delete…", role: .destructive) {
                store.confirmation = PixelConfirmation(
                    title: "Delete the memory “\(entry.title)”?",
                    message: "Its file and its line in MEMORY.md go away; Claude won't recall it in new sessions.",
                    action: "Delete"
                ) { store.deleteMemory(entry, in: memory); revision += 1 }
            }
        }
    }

    static func loading(_ item: Sources.Instruction) -> String {
        switch item.loading {
        case .always: "every turn"
        case let .paths(paths): "when reading \(paths.joined(separator: ", "))" + (item.isLoaded ? " · loaded" : "")
        case .nested: "when reading files in its folder" + (item.isLoaded ? " · loaded" : "")
        }
    }

    private func section(_ title: String, @ViewBuilder _ rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.textDim)
            rows()
        }
    }

    private func row(_ name: String, _ tokens: Int, of usage: ContextUsage) -> some View {
        HStack(spacing: 6) {
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(TokenFormat.short(tokens)).font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
        }
        .font(Fonts.ui(13))
        .help("\(name): \(tokens) tokens, \(usage.window > 0 ? tokens * 100 / usage.window : 0)% of the window")
    }

    /// A file opens in meepo's editor: change what Claude reads, right there.
    private func fileRow(_ path: String, detail: String, tokens: Int?, isEstimate: Bool = false, showsPath: Bool = true) -> some View {
        Button { store.editor.open(path) } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(URL(filePath: path).lastPathComponent).lineLimit(1)
                    Text(showsPath ? "\(detail) · \(Self.shortPath(path))" : detail).font(.caption).foregroundStyle(Tokens.textDim)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let tokens { Text((isEstimate ? "≈" : "") + TokenFormat.short(tokens)).font(Fonts.mono(12)).foregroundStyle(Tokens.textDim) }
            }
            .font(Fonts.ui(13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(path) in the editor")
    }

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Tokens.line)
                Rectangle().fill(fraction >= store.relayThreshold ? Tokens.need : Tokens.work)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }

    private func dim(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
    }

    static func reason(_ raw: String) -> String {
        switch raw {
        case "path_glob_match": "a matching file was read"
        case "nested_traversal": "a folder below was opened"
        case "include": "included by another file"
        case "compact": "reloaded after compact"
        default: raw
        }
    }

    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// The status bar's context: the selected session's fill; a click opens the Context panel over it — in Solo, where
/// no panel is around, this is where the context is. Orange from the relay threshold on, as the bar's RELAY was.
struct ContextChip: View {
    @Environment(AppStore.self) private var store
    @State private var isOpen = false

    var body: some View {
        if let id = store.selectedSession?.id, !store.isHomeShown {
            let percent = store.contextUsage[id]?.percent
            Button(percent.map { "Context \($0)%" } ?? "Context") { isOpen.toggle() }
                .buttonStyle(.plain)
                .foregroundStyle((percent ?? 0) >= Int(store.relayThreshold * 100) ? Tokens.need : Tokens.textDim)
                .help("What fills this session's context, and room left")
                .popover(isPresented: $isOpen, arrowEdge: .top) {
                    ScrollView { ContextPanel().padding(14) }
                        .frame(width: 340)
                        .frame(maxHeight: 560)
                        .background(Tokens.surface)
                }
        }
    }
}
