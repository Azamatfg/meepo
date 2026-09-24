import SwiftUI

/// The right panel (redesign 2026-09-24): everything about the selected session in one column, no tabs —
/// what it waits for, what it changed (committed or not) with DIFF / EXPLAIN, what isn't pushed, its project's
/// CI in one line, and its latest events. Details open in sheets.
struct SessionInspector: View {
    @Environment(AppStore.self) private var store
    @State private var scm: GitPanel.SourceControl?
    /// What the compare view shows; nil = closed.
    @State private var compare: Compare?
    @State private var explanation: (title: String, text: String)?
    /// Which EXPLAIN is running ("changes", "incoming").
    @State private var explaining: String?
    @State private var isSyncing = false
    @State private var isCIShown = false
    @State private var areEventsShown = false

    var body: some View {
        Group {
            if let session = store.selectedSession, let project = store.project(for: session), let path = store.workdir(of: session) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        header(session, project)
                        sourceControl(path: path)
                        ciSection(project, session)
                        eventsSection
                    }
                    .padding(8)
                }
                .task(id: path) {
                    scm = nil
                    explanation = nil
                    while !Task.isCancelled {
                        scm = await Task.detached { GitPanel.sourceControl(in: path) }.value
                        try? await Task.sleep(for: .seconds(10))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a session to see what it's doing and what it changed.")
                        .font(.caption).foregroundStyle(Tokens.textDim)
                    Button("ALL CI") { isCIShown = true }.buttonStyle(PixelButtonStyle())
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Tokens.dirt)
        .sheet(isPresented: Binding(get: { compare != nil }, set: { if !$0 { compare = nil } })) {
            if let compare, let path = store.selectedSession.flatMap(store.workdir(of:)) {
                DiffViewer(title: compare.title, sources: compare.sources(in: path), selected: compare.selected)
            }
        }
        .sheet(isPresented: $isCIShown) { CISheet() }
        .sheet(isPresented: $areEventsShown) { EventsSheet() }
    }

    // MARK: Header

    private func header(_ session: Session, _ project: Project) -> some View {
        let look = store.look(of: session)
        let place = session.worktreeName.map { "worktree \($0)" } ?? "\(project.name) · \(session.branch ?? "")"
        return VStack(alignment: .leading, spacing: 4) {
            Text(project.name.uppercased()).font(Fonts.title(16)).foregroundStyle(Tokens.text).lineLimit(1)
            Text(session.branch ?? "").font(Fonts.mono(12)).foregroundStyle(Tokens.textDim).lineLimit(1)
            Text(look.text).font(.caption).foregroundStyle(look.ring == .waiting ? Tokens.alert : Tokens.textDim)
            HStack(spacing: 6) {
                Button("NEW SESSION") {
                    store.confirmation = PixelConfirmation(
                        title: "START A FRESH SESSION?",
                        message: "A new claude in \(place), with a clean context. This one is closed; its conversation stays in Claude Code (claude --resume).",
                        action: "NEW SESSION",
                        isDestructive: false
                    ) { try? store.replaceSession(session.id!) }
                }
                .help("Close this session and start a clean one in the same folder")
                Button("CLOSE") {
                    store.confirmation = PixelConfirmation(
                        title: "CLOSE THIS SESSION?",
                        message: "claude stops. Files and commits stay; the conversation stays in Claude Code (claude --resume).",
                        action: "CLOSE"
                    ) { store.closeSession(session.id!) }
                }
                .help("Stop claude and remove the session from Meepo")
            }
            .buttonStyle(PixelButtonStyle(compact: true))
        }
    }

    // MARK: Source Control — CHANGES, INCOMING, OUTGOING (like VS Code)

    @ViewBuilder
    private func sourceControl(path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let scm {
                changesGroup(scm, path: path)
                if !scm.incoming.commits.isEmpty { incomingGroup(scm, path: path) }
                if !scm.outgoing.commits.isEmpty || scm.upstream == nil { outgoingGroup(scm, path: path) }
                if let explanation {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("EXPLAINED · \(explanation.title)").font(.caption).foregroundStyle(Tokens.screen)
                            Spacer()
                            Button("✕") { self.explanation = nil }.buttonStyle(.plain).foregroundStyle(Tokens.textDim)
                        }
                        Text(explanation.text).font(.caption).foregroundStyle(Tokens.text).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6).background(Tokens.terminalBg).sunken()
                }
            } else {
                Text("Reading git…").font(.caption).foregroundStyle(Tokens.textDim)
            }
        }
        .padding(6)
        .background(Tokens.grassDeep)
    }

    private func changesGroup(_ scm: GitPanel.SourceControl, path: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            GroupHeader(title: "CHANGES", count: "\(scm.changes.count)", hint: "not committed yet")
            if scm.changes.isEmpty {
                Text("Nothing uncommitted.").font(.caption).foregroundStyle(Tokens.textDim)
            }
            ForEach(scm.changes) { change in
                FileRow(change: change) { compare = Compare(title: "Working Tree", files: scm.changes, selected: change.path, old: "HEAD", new: nil) }
            }
            if !scm.changes.isEmpty {
                actions {
                    Button("COMPARE") { compare = Compare(title: "Working Tree", files: scm.changes, selected: scm.changes[0].path, old: "HEAD", new: nil) }
                    Button(explaining == "changes" ? "…" : "EXPLAIN") {
                        explain("changes", title: "your changes", path: path, from: "HEAD", to: nil,
                                whose: "the user's uncommitted", newFiles: scm.changes.filter { $0.status == "?" }.map(\.path))
                    }
                }
            }
        }
    }

    private func incomingGroup(_ scm: GitPanel.SourceControl, path: String) -> some View {
        let group = scm.incoming
        return VStack(alignment: .leading, spacing: 3) {
            GroupHeader(title: "INCOMING", count: "↓\(group.commits.count)", hint: "from \(scm.upstream ?? "the remote")")
            ForEach(group.commits) { CommitRow(commit: $0) }
            ForEach(group.files) { change in
                FileRow(change: change) { compare = Compare(title: "Incoming", files: group.files, selected: change.path, old: group.from, new: group.to) }
            }
            actions {
                if scm.changes.isEmpty {
                    Button("PULL") { Task { await sync(path) { GitPanel.pullRebase(in: path) } } }
                        .help("git pull --rebase: their commits come in, yours go on top")
                }
                Button(explaining == "incoming" ? "…" : "EXPLAIN") {
                    explain("incoming", title: "what teammates changed", path: path, from: group.from ?? "HEAD", to: group.to,
                            whose: "the teammates' incoming", newFiles: [])
                }
            }
            if !scm.changes.isEmpty {
                Text("Pulled automatically once your changes are committed.").font(.caption2).foregroundStyle(Tokens.textDim)
            }
        }
    }

    private func outgoingGroup(_ scm: GitPanel.SourceControl, path: String) -> some View {
        let group = scm.outgoing
        return VStack(alignment: .leading, spacing: 3) {
            GroupHeader(title: "OUTGOING", count: scm.upstream == nil ? "new branch" : "↑\(group.commits.count)",
                        hint: scm.upstream == nil ? "not on the remote yet" : "to \(scm.upstream ?? "")")
            ForEach(group.commits) { CommitRow(commit: $0) }
            ForEach(group.files) { change in
                FileRow(change: change) { compare = Compare(title: "Outgoing", files: group.files, selected: change.path, old: group.from, new: group.to) }
            }
            actions {
                Button(scm.upstream == nil ? "PUBLISH" : "PUSH") { askPush(scm, path: path) }
                    .disabled(!scm.incoming.commits.isEmpty)
                    .help(scm.incoming.commits.isEmpty ? "git push, never forced" : "Take the incoming commits first (PULL)")
            }
        }
    }

    private func actions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .buttonStyle(PixelButtonStyle(compact: true))
            .disabled(isSyncing)
            .padding(.top, 2)
    }

    private func askPush(_ scm: GitPanel.SourceControl, path: String) {
        let main = GitPanel.isMainBranch(scm.branch)
        let status = GitPanel.Snapshot(branch: scm.branch, upstream: scm.upstream, ahead: scm.ahead, behind: scm.behind)
        store.confirmation = PixelConfirmation(
            title: scm.upstream == nil ? "PUBLISH \(scm.branch.uppercased())?" : "PUSH \(scm.ahead) COMMITS?",
            message: "To \(scm.upstream ?? "origin/\(scm.branch)"). Never forced." + (main
                ? " This is the main branch: the commits go live for everyone, and CI/deploy may start. /ship usually does this after its checks."
                : ""),
            action: "PUSH",
            isDestructive: main
        ) { Task { await sync(path) { GitPanel.push(status, in: path) } } }
    }

    private func sync(_ path: String, _ run: @escaping @Sendable () -> String?) async {
        isSyncing = true
        defer { isSyncing = false }
        if let error = await Task.detached(operation: run).value { store.bridgeError = error }
        scm = await Task.detached { GitPanel.sourceControl(in: path) }.value
    }

    private func explain(_ key: String, title: String, path: String, from: String, to: String?, whose: String, newFiles: [String]) {
        explaining = key
        Task {
            defer { explaining = nil }
            do {
                let text = try await store.explainChanges(in: path, from: from, to: to, whose: whose, newFiles: newFiles)
                explanation = (title, text)
            } catch {
                store.bridgeError = error.localizedDescription
            }
        }
    }

    // MARK: CI in one line

    @ViewBuilder
    private func ciSection(_ project: Project, _ session: Session) -> some View {
        let runs = store.ciRuns[project.id!] ?? []
        let pipeline = store.pipelines[project.id!]
        let failing = runs.first { $0.headBranch == session.branch && $0.failed && $0.headBranch != pipeline?.branch }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("CI").font(Fonts.title(16)).foregroundStyle(Tokens.text)
                if let pipeline {
                    ForEach(pipeline.steps) { step in
                        Text(StepLook.symbol(step.state) + step.name).font(Fonts.mono(11))
                            .foregroundStyle(StepLook.color(step.state)).lineLimit(1)
                    }
                } else if runs.isEmpty {
                    Text("no CI").font(.caption).foregroundStyle(Tokens.textDim)
                }
                Spacer(minLength: 0)
                Button("ALL") { isCIShown = true }.buttonStyle(PixelButtonStyle(compact: true))
                    .help("Every project's CI, with autofix and other branches")
            }
            if let pipeline, let step = pipeline.steps.first(where: { $0.trigger != nil && pipeline.canStart($0) }) {
                HStack {
                    Text("\(step.name) ready on \(pipeline.branch) @ \(pipeline.sha.prefix(7))").font(.caption).foregroundStyle(Tokens.textDim)
                    Spacer()
                    Button("RUN") {
                        store.confirmation = PixelConfirmation(
                            title: "RUN \(step.name.uppercased())?",
                            message: "\(project.name) · \(pipeline.branch) @ \(pipeline.sha.prefix(7))",
                            action: "RUN"
                        ) { Task { await store.startPipelineStep(step, in: project) } }
                    }
                    .buttonStyle(PixelButtonStyle(compact: true))
                }
            }
            if let head = runs.first(where: { $0.headBranch == pipeline?.branch }), head.isInfraFailure {
                Text("\(head.failureReason ?? "") — CI didn't run the code").font(.caption).foregroundStyle(Tokens.warn)
            }
            if let failing { CIRunRow(run: failing, project: project) }
        }
        .padding(6)
        .background(Tokens.grassDeep)
    }

    // MARK: Events

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("EVENTS").font(Fonts.title(16)).foregroundStyle(Tokens.text)
                Spacer()
                if store.selectedEvents.count > 5 {
                    Button("ALL") { areEventsShown = true }.buttonStyle(PixelButtonStyle(compact: true))
                }
            }
            if store.selectedEvents.isEmpty {
                Text(store.isBridgeInstalled ? "No events yet" : "Install the bridge to see events")
                    .font(.caption).foregroundStyle(Tokens.textDim)
            }
            ForEach(store.selectedEvents.prefix(5)) { EventRow(event: $0) }
        }
        .padding(6)
        .background(Tokens.grassDeep)
    }
}

/// What the compare view opens: a group's files, which one first, and the two sides (`new` nil = on disk).
private struct Compare {
    let title: String
    let files: [GitPanel.FileChange]
    let selected: String
    let old: String?
    let new: String?

    func sources(in path: String) -> [DiffSource] {
        files.map { change in
            let (old, new) = (old, new)
            return DiffSource(id: change.path, status: change.status, added: change.added, removed: change.removed,
                              isUncommitted: change.isUncommitted) { GitPanel.versions(of: change, old: old, new: new, in: path) }
        }
    }
}

/// "INCOMING ↓1 from origin/main".
private struct GroupHeader: View {
    let title: String
    let count: String
    let hint: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(Fonts.title(16)).foregroundStyle(Tokens.text)
            Text(count).font(Fonts.mono(12)).foregroundStyle(Tokens.warn)
            Spacer(minLength: 0)
            Text(hint).font(.caption2).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// "Rustem · fix api endpoint · 2 hours ago".
private struct CommitRow: View {
    let commit: GitPanel.CommitLine

    var body: some View {
        HStack(spacing: 4) {
            Text(commit.author).font(.caption.weight(.semibold)).foregroundStyle(Tokens.screen).lineLimit(1).fixedSize()
            Text(commit.subject).font(.caption).foregroundStyle(Tokens.text).lineLimit(1)
            Spacer(minLength: 2)
            Text(commit.when).font(.caption2).foregroundStyle(Tokens.textDim).lineLimit(1).fixedSize()
        }
        .help("\(commit.sha) · \(commit.author) · \(commit.subject)")
    }
}

/// Every project's CI (the former CI tab's ALL view) in a sheet.
private struct CISheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CI").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
            }
            CIView(showAll: true).background(Tokens.dirt).sunken()
        }
        .padding(16)
        .frame(width: 560, height: 620)
        .background(Tokens.grass)
        .pixelFrame(6)
        .preferredColorScheme(.dark)
    }
}

/// The selected session's whole event feed.
private struct EventsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("EVENTS").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.selectedEvents) { EventRow(event: $0) }
                }
                .padding(8)
            }
            .background(Tokens.dirt).sunken()
        }
        .padding(16)
        .frame(width: 560, height: 620)
        .background(Tokens.grass)
        .pixelFrame(6)
        .preferredColorScheme(.dark)
    }
}

/// One changed file as in VS Code's Source Control: type icon, name, folder, status letter; a click compares it.
struct FileRow: View {
    let change: GitPanel.FileChange
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: FileIcon.symbol(for: change.path)).font(.system(size: 11))
                    .foregroundStyle(FileIcon.color(for: change.path)).frame(width: 14)
                Text(URL(filePath: change.path).lastPathComponent).font(.system(size: 12))
                    .foregroundStyle(change.status == "D" ? Tokens.textDim : Tokens.text)
                    .strikethrough(change.status == "D").lineLimit(1)
                Text((change.path as NSString).deletingLastPathComponent)
                    .font(.system(size: 11)).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                Text(DiffViewer.letter(change.status)).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DiffViewer.color(change.status))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(label): \(change.path)\(counts) — click to compare")
    }

    private var counts: String {
        let added = change.added.map { " +\($0)" } ?? "", removed = change.removed.map { " −\($0)" } ?? ""
        return added + removed
    }

    private var label: String {
        switch change.status {
        case "A": "added"
        case "?": "untracked (new, not in git yet)"
        case "D": "deleted"
        case "R": "renamed"
        default: "modified"
        }
    }
}

/// A file-type icon, the way VS Code's file list tells files apart at a glance.
enum FileIcon {
    static func symbol(for path: String) -> String {
        switch URL(filePath: path).pathExtension.lowercased() {
        case "swift": "swift"
        case "md", "txt", "rst": "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "ini", "env", "lock": "gearshape"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico": "photo"
        case "html", "htm", "css", "scss": "globe"
        case "sh", "zsh", "bash": "terminal"
        case "sql": "cylinder"
        case "": "doc"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }

    static func color(for path: String) -> Color {
        switch URL(filePath: path).pathExtension.lowercased() {
        case "swift": Tokens.alert
        case "md", "txt", "rst": Tokens.screen
        case "json", "yml", "yaml", "toml", "plist", "ini", "env", "lock": Tokens.warn
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico": Tokens.selectionSoft
        default: Tokens.textDim
        }
    }
}
