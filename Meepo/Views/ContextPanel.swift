import SwiftUI

/// The selected session's context window by part, as /context breaks it down, measured by the mod after each
/// answer: what fills it, which CLAUDE.md and memory files, what loaded on demand, skills and MCP — and what to do
/// about it (compact, clear, hand off to a fresh session).
struct ContextPanel: View {
    @Environment(AppStore.self) private var store

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
                actions(id)
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
    private func fileRow(_ path: String, detail: String, tokens: Int?) -> some View {
        Button { store.editor.open(path) } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(URL(filePath: path).lastPathComponent).lineLimit(1)
                    Text("\(detail) · \(Self.shortPath(path))").font(.caption).foregroundStyle(Tokens.textDim)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let tokens { Text(TokenFormat.short(tokens)).font(Fonts.mono(12)).foregroundStyle(Tokens.textDim) }
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
