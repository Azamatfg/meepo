import SwiftUI

/// TOOLS sheet (SPEC module 11): shared practices across projects, and Docker upkeep.
struct ToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.practices
    @State private var confirmation: PixelConfirmation?

    enum Tab: String, CaseIterable { case practices = "PRACTICES", docker = "DOCKER" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TOOLS").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                ForEach(Tab.allCases, id: \.self) { item in
                    Button(item.rawValue) { tab = item }
                        .overlay { if tab == item { Bevel(raised: false) } }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(confirmation == nil ? .cancelAction : nil)
            }
            .buttonStyle(PixelButtonStyle())
            switch tab {
            case .practices: PracticesView(confirmation: $confirmation)
            case .docker: DockerView(confirmation: $confirmation)
            }
        }
        .padding(16)
        .frame(width: 760, height: 600)
        .background(Tokens.grass)
        .pixelFrame(6)
        .pixelConfirm($confirmation)
        .preferredColorScheme(.dark)
    }
}

private struct PracticesView: View {
    @Environment(AppStore.self) private var store
    @State private var items: [Library.Item] = []
    @State private var showAll = false
    @State private var expanded: String?
    @State private var isPickingLibrary = false
    @Binding var confirmation: PixelConfirmation?

    var body: some View {
        let library = store.libraryURL
        let shown = showAll ? items : items.filter { item in item.copies.contains { $0.state != .same } }
        let outdatedTotal = items.flatMap(\.copies).filter { $0.state == .outdated }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Library: \(library.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    .font(Fonts.mono(12)).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.middle)
                Button("CHANGE") { isPickingLibrary = true }
                Spacer()
                Button(showAll ? "ONLY DIFFERENCES" : "SHOW ALL") { showAll.toggle() }
                Button("UPDATE ALL (\(outdatedTotal))") {
                    confirmation = PixelConfirmation(
                        title: "OVERWRITE \(outdatedTotal) OUTDATED COPIES?",
                        message: "Older isn't always outdated: a copy may be tuned for its project. Check DIFF first if unsure. Backups are kept.",
                        action: "OVERWRITE"
                    ) { act { for item in items { try Library.updateOutdated(item, backups: backups) } } }
                }
                .disabled(outdatedTotal == 0)
                .help("Library → every outdated copy. Copies edited in a project are left alone.")
            }
            .buttonStyle(PixelButtonStyle())
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if shown.isEmpty {
                        Text(showAll ? "No commands, hooks or agents found." : "Every copy matches the library.")
                            .foregroundStyle(Tokens.textDim)
                    }
                    ForEach(shown) { item in
                        PracticeRow(item: item, isExpanded: expanded == item.id, library: library, backups: backups,
                                    confirmation: $confirmation, onToggle: { expanded = expanded == item.id ? nil : item.id }, act: act)
                    }
                }
                .padding(6)
            }
            .background(Tokens.dirt)
            .sunken()
            Text("outdated = library is newer · edited = changed in the project · local = not in the library. Backups: ~/.meepo/backups/practices")
                .font(.caption).foregroundStyle(Tokens.textDim)
        }
        .onAppear(perform: reload)
        .onChange(of: store.libraryFolder) { reload() }
        .fileImporter(isPresented: $isPickingLibrary, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() { store.libraryFolder = url.path }
        }
    }

    private var backups: URL { MeepoHome.url.appending(path: "backups") }

    private func reload() { items = Library.scan(library: store.libraryURL, projects: store.projects) }

    private func act(_ change: () throws -> Void) {
        do { try change() } catch { store.bridgeError = error.localizedDescription }
        reload()
        store.refreshProjects()
    }
}

private struct PracticeRow: View {
    let item: Library.Item
    let isExpanded: Bool
    let library: URL
    let backups: URL
    @Binding var confirmation: PixelConfirmation?
    let onToggle: () -> Void
    let act: (() throws -> Void) -> Void
    @State private var diffCopy: Library.Copy?

    var body: some View {
        let counts = Dictionary(grouping: item.copies, by: \.state).mapValues(\.count)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(item.kind)/\(item.name)").font(Fonts.mono(13)).foregroundStyle(Tokens.text)
                if item.libraryURL == nil { Text("LOCAL").font(.caption2).foregroundStyle(Tokens.warn) }
                Spacer()
                badge(counts[.outdated], "outdated", Tokens.alert)
                badge(counts[.newer], "edited", Tokens.warn)
                badge(counts[.same], "same", Tokens.selectionSoft)
                if let outdated = counts[.outdated], outdated > 0 {
                    Button("UPDATE \(outdated)") {
                        confirmation = PixelConfirmation(
                            title: "OVERWRITE \(item.name.uppercased())?",
                            message: "In: \(item.copies.filter { $0.state == .outdated }.map(\.project.name).joined(separator: ", ")). Backups are kept.",
                            action: "OVERWRITE"
                        ) { act { try Library.updateOutdated(item, backups: backups) } }
                    }
                    .buttonStyle(PixelButtonStyle())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            if isExpanded {
                ForEach(item.copies) { copy in
                    HStack(spacing: 8) {
                        Text(copy.project.name).foregroundStyle(Tokens.text).frame(width: 160, alignment: .leading)
                        Text(label(copy.state)).font(.caption).foregroundStyle(color(copy.state))
                        Spacer()
                        if copy.state != .same {
                            Button("DIFF") { diffCopy = copy }
                                .popover(isPresented: Binding(get: { diffCopy?.id == copy.id }, set: { if !$0 { diffCopy = nil } })) {
                                    DiffText(text: Library.diff(copy, against: item))
                                }
                        }
                        if copy.state == .newer || copy.state == .projectOnly {
                            Button("LIFT") { act { try Library.lift(copy, in: item, library: library, backups: backups) } }
                                .help("Make this project's version the library version")
                        }
                        if copy.state == .newer || copy.state == .outdated {
                            Button("OVERWRITE") { act { try Library.overwrite(copy, from: item, backups: backups) } }
                                .help("Replace this project's copy with the library version (backed up)")
                        }
                    }
                    .buttonStyle(PixelButtonStyle())
                    .padding(.leading, 12)
                }
            }
        }
        .padding(6)
        .background(isExpanded ? Tokens.grassDeep : .clear)
    }

    @ViewBuilder
    private func badge(_ count: Int?, _ title: String, _ color: Color) -> some View {
        if let count, count > 0 { Text("\(count) \(title)").font(.caption).foregroundStyle(color) }
    }

    private func label(_ state: Library.State) -> String {
        switch state {
        case .same: "same"
        case .outdated: "outdated"
        case .newer: "edited in project"
        case .projectOnly: "local only"
        }
    }

    private func color(_ state: Library.State) -> Color {
        switch state {
        case .same: Tokens.selectionSoft
        case .outdated: Tokens.alert
        case .newer, .projectOnly: Tokens.warn
        }
    }
}

private struct DockerView: View {
    @Environment(AppStore.self) private var store
    @State private var usage: [Docker.Usage] = []
    @State private var stopped: [Docker.Container] = []
    @State private var state = "Loading…"
    @Binding var confirmation: PixelConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if usage.isEmpty {
                Text(state).foregroundStyle(Tokens.textDim)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["", "size", "reclaimable"], id: \.self) { Text($0).font(.caption).foregroundStyle(Tokens.textDim) }
                    }
                    ForEach(usage, id: \.type) { row in
                        GridRow {
                            Text(row.type).foregroundStyle(Tokens.text)
                            Text(row.size).font(Fonts.mono(12)).foregroundStyle(Tokens.text)
                            Text(row.reclaimable).font(Fonts.mono(12)).foregroundStyle(Tokens.warn)
                        }
                    }
                }
                .padding(8).background(Tokens.dirt).sunken()

                Text("STOPPED CONTAINERS BY PROJECT").font(Fonts.title(16)).foregroundStyle(Tokens.text)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.name) { group in
                        Text("\(group.name): \(group.containers.count)")
                            .font(Fonts.mono(12)).foregroundStyle(group.isMeepo ? Tokens.text : Tokens.textDim)
                    }
                    if stopped.isEmpty { Text("None").foregroundStyle(Tokens.textDim) }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Tokens.dirt).sunken()

                HStack {
                    ForEach(Docker.Cleanup.allCases) { cleanup in
                        Button("CLEAN \(cleanup.rawValue.uppercased())") {
                            confirmation = PixelConfirmation(
                                title: "REMOVE \(cleanup.rawValue.uppercased())?",
                                message: "docker \(cleanup.args.joined(separator: " ")). Running containers and tagged images are kept.",
                                action: "REMOVE"
                            ) { Task { await clean(cleanup) } }
                        }
                    }
                }
                .buttonStyle(PixelButtonStyle())
            }
            Spacer()
        }
        .task { await load() }
    }

    /// Compose projects matched to Meepo projects by folder name; the rest listed as they are.
    private var groups: [(name: String, containers: [Docker.Container], isMeepo: Bool)] {
        let byCompose = Dictionary(grouping: stopped) { $0.composeProject ?? "(no compose project)" }
        return byCompose.map { compose, containers in
            let project = store.projects.first { Docker.composeName(of: $0) == compose }
            return (project?.name ?? compose, containers, project != nil)
        }
        .sorted { ($0.isMeepo ? 0 : 1, $0.name) < ($1.isMeepo ? 0 : 1, $1.name) }
    }

    private func load() async {
        guard let docker = store.toolPath("docker") else { state = "Docker isn't installed."; return }
        let (df, ps) = await Task.detached {
            (Docker.run(docker, ["system", "df", "--format", "{{json .}}"]),
             Docker.run(docker, ["ps", "-a", "--filter", "status=exited", "--format", "{{json .}}"]))
        }.value
        guard let df else { state = "Docker isn't running."; return }
        usage = Docker.parseUsage(df)
        stopped = Docker.parseContainers(ps ?? "")
    }

    private func clean(_ cleanup: Docker.Cleanup) async {
        guard let docker = store.toolPath("docker") else { return }
        _ = await Task.detached { Docker.run(docker, cleanup.args) }.value
        await load()
    }
}

/// Unified diff, colored by line.
private struct DiffText: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(Fonts.mono(11))
                        .foregroundStyle(line.hasPrefix("+") ? Tokens.selection : line.hasPrefix("-") ? Tokens.danger
                                         : line.hasPrefix("@@") ? Tokens.screen : Tokens.text)
                }
            }
            .padding(8)
        }
        .frame(width: 620, height: 420)
        .background(Tokens.terminalBg)
        .preferredColorScheme(.dark)
    }
}
