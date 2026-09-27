import SwiftUI

/// Source Control as a panel (VS Code's CHANGES / INCOMING / OUTGOING) for every repo the selected session
/// works in — its folder, the repos inside a plain folder, and "Also work in" projects — each with COMPARE
/// and EXPLAIN. The shell keeps `store.sourceControls` fresh; the panel only acts on them.
struct SourceControlPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let session = store.selectedSession, let folder = store.workdir(of: session) {
            let repos = store.sessionRepos
            if repos.count <= 1 {
                RepoSourceControl(path: repos.first?.path ?? folder)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(repos) { repo in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .semibold))
                                Text(repo.name).font(Fonts.ui(14, weight: .bold))
                                if repo.isLinked { Text("also works here").font(.caption2).foregroundStyle(Tokens.work) }
                                Text(store.sourceControls[repo.path]?.branch ?? "").font(Fonts.mono(11)).foregroundStyle(Tokens.textDim)
                            }
                            RepoSourceControl(path: repo.path)
                        }
                    }
                }
            }
        } else {
            Text("Select a session to see what it changed.").font(.caption).foregroundStyle(Tokens.textDim)
        }
    }
}

/// One repo's CHANGES / INCOMING / OUTGOING.
private struct RepoSourceControl: View {
    @Environment(AppStore.self) private var store
    let path: String
    /// What the compare view shows; nil = closed.
    @State private var compare: Compare?
    @State private var explanation: (title: String, text: String)?
    /// Which EXPLAIN is running ("changes", "incoming").
    @State private var explaining: String?
    @State private var isSyncing = false
    /// The history commit whose card is open.
    @State private var openedCommit: String?

    private var scm: GitPanel.SourceControl? { store.sourceControls[path] }

    var body: some View {
        sourceControl(path: path)
            .onChange(of: path) { explanation = nil }
            .sheet(isPresented: Binding(get: { compare != nil }, set: { if !$0 { compare = nil } })) {
                if let compare {
                    DiffViewer(title: compare.title, sources: compare.sources(in: path), selected: compare.selected)
                }
            }
    }

    // MARK: Source Control — CHANGES, INCOMING, OUTGOING (like VS Code)

    @ViewBuilder
    private func sourceControl(path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let scm, !scm.isRepository {
                HStack {
                    Text("Not a git repository").font(.caption).foregroundStyle(Tokens.textDim)
                    Spacer()
                    Button("Git init") {
                        store.confirmation = PixelConfirmation(
                            title: "Start git here?",
                            message: "git init in \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")): changes get tracked, and branches, worktrees and compare turn on. Nothing is committed or pushed.",
                            action: "Git init",
                            isDestructive: false
                        ) { Task { await sync(path) { GitService.runReportingError(["init"], in: path) } } }
                    }
                    .buttonStyle(PixelButtonStyle(compact: true))
                }
            } else if let scm {
                changesGroup(scm, path: path)
                if !scm.incoming.commits.isEmpty { incomingGroup(scm, path: path) }
                if !scm.outgoing.commits.isEmpty || scm.upstream == nil { outgoingGroup(scm, path: path) }
                if !scm.history.isEmpty { historyGroup(scm) }
                if let explanation {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Explained · \(explanation.title)").font(.caption).foregroundStyle(Tokens.screen)
                            Spacer()
                            Button("✕") { self.explanation = nil }.buttonStyle(.plain).foregroundStyle(Tokens.textDim)
                        }
                        Text(MarkdownText.attributed(explanation.text)).font(.caption).foregroundStyle(Tokens.text).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8).background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                Text("Reading git…").font(.caption).foregroundStyle(Tokens.textDim)
            }
        }
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
                    Button("Compare") { compare = Compare(title: "Working Tree", files: scm.changes, selected: scm.changes[0].path, old: "HEAD", new: nil) }
                    Button(explaining == "changes" ? "…" : "Explain") {
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
                    Button("Pull") { Task { await sync(path) { GitPanel.pullRebase(in: path) } } }
                        .help("git pull --rebase: their commits come in, yours go on top")
                }
                Button(explaining == "incoming" ? "…" : "Explain") {
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
                Button(scm.upstream == nil ? "Publish" : "Push") { askPush(scm, path: path) }
                    .disabled(!scm.incoming.commits.isEmpty)
                    .help(scm.incoming.commits.isEmpty ? "git push, never forced" : "Take the incoming commits first (PULL)")
            }
        }
    }

    /// The branch's last commits with their short hash; a click opens the commit like VS Code's Git Graph hover.
    private func historyGroup(_ scm: GitPanel.SourceControl) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            GroupHeader(title: "HISTORY", count: scm.branch, hint: "last \(scm.history.count) commits")
            ForEach(scm.history) { commit in
                Button { openedCommit = commit.sha } label: {
                    HStack(spacing: 6) {
                        Text(commit.sha).font(Fonts.mono(11)).foregroundStyle(Tokens.work).fixedSize()
                        CommitRow(commit: commit)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { openedCommit == commit.sha }, set: { if !$0 { openedCommit = nil } }),
                         arrowEdge: .trailing) {
                    CommitCard(sha: commit.sha, path: path) { detail, file in
                        openedCommit = nil
                        compare = Compare(title: detail.message.components(separatedBy: "\n")[0], files: detail.files, selected: file.path,
                                          old: detail.parent, new: detail.sha)
                    }
                }
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
            title: scm.upstream == nil ? "Publish \(scm.branch)?" : "Push \(scm.ahead) commits?",
            message: "To \(scm.upstream ?? "origin/\(scm.branch)"). Never forced." + (main
                ? " This is the main branch: the commits go live for everyone, and CI/deploy may start. /ship usually does this after its checks."
                : ""),
            action: "Push",
            isDestructive: main
        ) { Task { await sync(path) { GitPanel.push(status, in: path) } } }
    }

    private func sync(_ path: String, _ run: @escaping @Sendable () -> String?) async {
        isSyncing = true
        defer { isSyncing = false }
        if let error = await Task.detached(operation: run).value { store.bridgeError = error }
        await store.refreshSourceControl(path)
        await store.refreshWork(containing: path) // a push is a new unit in What changed
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
}

/// The selected session's project CI: pipeline steps, RUN for a manual step, the failing run of this branch.
struct CIPanel: View {
    @Environment(AppStore.self) private var store
    @State private var isCIShown = false

    var body: some View {
        Group {
            if let session = store.selectedSession, let project = store.project(for: session) {
                VStack(alignment: .leading, spacing: 12) {
                    if project.remote != nil || store.sessionRepos.count <= 1 { ciSection(project, session) }
                    // Repos inside a plain project folder, and "Also work in" folders.
                    ForEach(store.sessionRepos.filter { $0.path != project.path }) { repo in
                        if let linked = store.projects.first(where: { $0.path == repo.path }) {
                            repoHeader(repo)
                            ciSection(linked, session)
                        } else if let ci = store.repoCI[repo.path] {
                            repoHeader(repo)
                            RepoCI(repo: repo, runs: ci.runs, pipeline: ci.pipeline)
                        }
                    }
                }
            } else {
                Button("All CI") { isCIShown = true }.buttonStyle(PixelButtonStyle(compact: true))
            }
        }
        .sheet(isPresented: $isCIShown) { CISheet() }
    }

    private func repoHeader(_ repo: Repo) -> some View {
        HStack(spacing: 6) {
            Text(repo.name).font(Fonts.ui(14, weight: .bold))
            if repo.isLinked { Text("also works here").font(.caption2).foregroundStyle(Tokens.work) }
        }
    }

    @ViewBuilder
    private func ciSection(_ project: Project, _ session: Session) -> some View {
        let runs = store.ciRuns[project.id!] ?? []
        let pipeline = store.pipelines[project.id!]
        let failing = runs.first { $0.headBranch == session.branch && $0.failed && $0.headBranch != pipeline?.branch }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if pipeline == nil {
                    Text(runs.isEmpty ? "No CI" : "No runs on the main branch yet").font(.caption).foregroundStyle(Tokens.textDim)
                }
                Spacer(minLength: 0)
                Button("All projects") { isCIShown = true }.buttonStyle(PixelButtonStyle(compact: true))
                    .help("Every project's CI, with autofix and other branches")
            }
            if let pipeline {
                PipelineView(pipeline: pipeline, runs: runs, project: project, name: project.name,
                             confirm: { store.confirmation = $0 }) {
                    await store.startPipelineStep($0, in: project)
                }
            }
            if let head = runs.first(where: { $0.headBranch == pipeline?.branch }), head.isInfraFailure {
                Text("\(head.failureReason ?? "") — CI didn't run the code").font(.caption).foregroundStyle(Tokens.warn)
            }
            if let failing { CIRunRow(run: failing, project: project) }
        }
    }
}

/// CI of a repo that isn't a Meepo project: the default branch's pipeline, RUN for a manual step, the
/// latest failed run. Shown, not acted on — autofix and notifications stay with projects.
private struct RepoCI: View {
    @Environment(AppStore.self) private var store
    let repo: Repo
    let runs: [CIRun]
    let pipeline: Pipeline?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pipeline {
                PipelineView(pipeline: pipeline, runs: runs, project: nil, name: repo.name,
                             confirm: { store.confirmation = $0 }) {
                    await store.startRepoPipelineStep($0, in: repo)
                }
            } else if runs.isEmpty {
                Text("No CI").font(.caption).foregroundStyle(Tokens.textDim)
            }
            if let failed = runs.first(where: \.failed) {
                Link("✗ \(failed.workflowName) on \(failed.headBranch)", destination: URL(string: failed.url) ?? URL(string: "about:blank")!)
                    .font(.caption).foregroundStyle(Tokens.danger)
            }
        }
    }
}

/// The selected session's latest hook events; ALL opens the whole feed.
struct EventsPanel: View {
    @Environment(AppStore.self) private var store
    @State private var areEventsShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.selectedEvents.isEmpty {
                Text(store.isBridgeInstalled ? "No events yet" : "Install the bridge to see events")
                    .font(.caption).foregroundStyle(Tokens.textDim)
            }
            EventStoryList(events: store.selectedEvents, limit: 10)
            if store.selectedEvents.count > 10 {
                Button("Everything") { areEventsShown = true }.buttonStyle(PixelButtonStyle(compact: true))
            }
        }
        .sheet(isPresented: $areEventsShown) { EventsSheet() }
    }
}

/// "INCOMING ↓1 from origin/main".
private struct GroupHeader: View {
    let title: String
    let count: String
    let hint: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.textDim)
            Text(count).font(Fonts.mono(12)).foregroundStyle(Tokens.warn)
            Spacer(minLength: 0)
            Text(hint).font(.caption2).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// "Rustem · fix api endpoint · 2 hours ago". A long author shortens instead of pushing the panel wider.
struct CommitRow: View {
    let commit: GitPanel.CommitLine

    var body: some View {
        HStack(spacing: 4) {
            Text(commit.author).font(.caption.weight(.semibold)).foregroundStyle(Tokens.screen).lineLimit(1)
            Text(commit.subject).font(.caption).foregroundStyle(Tokens.text).lineLimit(1)
            Spacer(minLength: 2)
            Text(commit.when).font(.caption2).foregroundStyle(Tokens.textDim).lineLimit(1).fixedSize()
        }
        .help("\(commit.sha) · \(commit.author) · \(commit.subject)")
    }
}

/// One commit, as VS Code shows it on hover: who and when, the whole message, the hash to copy, what it
/// changed (a file opens the compare view), and its page on GitHub or GitLab.
private struct CommitCard: View {
    let sha: String
    let path: String
    let onFile: (GitPanel.CommitDetail, GitPanel.FileChange) -> Void
    @State private var detail: GitPanel.CommitDetail?
    @State private var web: URL?
    @State private var isLoaded = false

    var body: some View {
        Group {
            if let detail {
                CommitCardContent(detail: detail, web: web) { onFile(detail, $0) }
            } else {
                Text(isLoaded ? "Can't read this commit." : "Reading…").foregroundStyle(Tokens.textDim)
                    .padding(14)
                    .frame(width: 420, alignment: .leading)
            }
        }
        .paperSheet()
        .task {
            let (sha, path) = (sha, path)
            (detail, web) = await Task.detached {
                let detail = GitPanel.detail(of: sha, in: path)
                return (detail, detail.flatMap { GitPanel.webURL(remote: GitService.remoteURL(in: path), commit: $0.sha) })
            }.value
            isLoaded = true
        }
    }
}

/// The card once the commit is read. A popover proposes no size and the commit loads after it opens, so the
/// card sizes itself to its content: without that the file list (a ScrollView with only a max height) got 0pt.
/// A long message and a long list scroll inside, so a big commit still fits on screen.
struct CommitCardContent: View {
    let detail: GitPanel.CommitDetail
    let web: URL?
    let onFile: (GitPanel.FileChange) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(detail.author).font(Fonts.ui(14, weight: .bold))
                Text(detail.date).font(.caption).foregroundStyle(Tokens.textDim).lineLimit(1)
            }
            ScrollView {
                Text(detail.message).font(Fonts.ui(13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            let added = detail.files.compactMap(\.added).reduce(0, +), removed = detail.files.compactMap(\.removed).reduce(0, +)
            Text("\(detail.files.count) file\(detail.files.count == 1 ? "" : "s") changed, ")
                + Text("\(added) insertions(+)").foregroundStyle(Tokens.added)
                + Text(", ") + Text("\(removed) deletions(−)").foregroundStyle(Tokens.danger)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(detail.files) { file in FileRow(change: file) { onFile(file) } }
                }
            }
            .frame(maxHeight: 160)
            HStack(spacing: 10) {
                Text(String(detail.sha.prefix(8))).font(Fonts.mono(12)).foregroundStyle(Tokens.work).textSelection(.enabled)
                Button("Copy hash") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail.sha, forType: .string)
                }
                if let first = detail.files.first {
                    Button("Compare") { onFile(first) }.help("The whole commit side by side, file by file")
                }
                if let web { Link(web.host()?.contains("gitlab") == true ? "Open on GitLab" : "Open on GitHub", destination: web) }
                Spacer()
            }
            .buttonStyle(PixelButtonStyle(compact: true))
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Every project's CI (the former CI tab's ALL view) in a sheet.
private struct CISheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CI").font(Fonts.title(22)).foregroundStyle(Tokens.text)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
            }
            CIView(showAll: true).background(Tokens.surface, in: RoundedRectangle(cornerRadius: 10)).sunken()
        }
        .padding(18)
        .frame(width: 560, height: 620)
        .paperSheet()
    }
}

/// The selected session's whole event feed.
private struct EventsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Events").font(Fonts.title(22)).foregroundStyle(Tokens.text)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
            }
            ScrollView {
                EventStoryList(events: store.selectedEvents).padding(8)
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 10)).sunken()
        }
        .padding(18)
        .frame(width: 560, height: 620)
        .paperSheet()
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
                    .foregroundStyle(FileIcon.statusColor(change.status))
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

    /// Source Control letter colors, readable on paper (the compare view keeps VS Code's own).
    static func statusColor(_ status: String) -> Color {
        switch status {
        case "A", "?": Tokens.added
        case "D": Tokens.danger
        default: Tokens.warn
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
