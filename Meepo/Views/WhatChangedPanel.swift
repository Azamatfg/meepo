import AppKit
import SwiftUI

/// What changed — what you sent, not each prompt: a block per push (its commits, the requests that led to it),
/// and on top what isn't sent yet. Explain for users says it in the product's words, on click.
struct WhatChangedPanel: View {
    @Environment(AppStore.self) private var store
    /// Units shown open; the newest one until the user picks.
    @State private var open: Set<String>?

    var body: some View {
        if let session = store.selectedSession, let folder = store.workdir(of: session) {
            if let folderWork = store.work[folder], folderWork.isGitRead {
                let blocks = (folderWork.repos.isEmpty ? [nil] : folderWork.repos.map(Optional.some)).map { repo in
                    let runs = repo.map { Work.runs(folderWork.runs, for: $0, in: folderWork.repos) } ?? folderWork.runs
                    return (repo: repo, units: Array(Work.units(repo, runs: runs).prefix(12)))
                }
                let focused = store.focusedUnit?.folder == folder ? store.focusedUnit?.unit : nil
                let shown = open ?? Set([focused ?? blocks.first?.units.first?.id].compactMap { $0 })
                VStack(alignment: .leading, spacing: 12) {
                    if blocks.allSatisfy({ $0.units.isEmpty }) {
                        Text("Nothing yet. Ask Claude for something — what you send shows up here, each push with the requests that led to it.")
                            .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(blocks, id: \.repo?.path) { repo, units in
                        if blocks.count > 1, let repo {
                            Text(repo.name).font(Fonts.ui(14, weight: .bold))
                        }
                        if repo == nil, !units.isEmpty {
                            Text("This folder isn't in git, so meepo can't tell what was sent — here are your requests.")
                                .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(units) { unit in
                            UnitBlock(unit: unit, repo: repo, folder: folder, session: session,
                                      summary: folderWork.summaries[unit.key], isOpen: shown.contains(unit.id)) {
                                var next = shown
                                if next.contains(unit.id) { next.remove(unit.id) } else { next.insert(unit.id) }
                                open = next
                            }
                        }
                    }
                }
                .onChange(of: store.focusedUnit) { if let unit = store.focusedUnit, unit.folder == folder { open = [unit.unit] } }
                .onChange(of: folder) { open = nil }
            } else {
                Text("Reading git…").font(.caption).foregroundStyle(Tokens.textDim)
                    .task(id: folder) { await store.refreshWork(folder) }
            }
        } else {
            Text("Select a session to see what it changed.").font(.caption).foregroundStyle(Tokens.textDim)
        }
    }
}

/// One unit: a push, a commit, or what isn't sent yet — its header, then (open) commits, files, CI, requests
/// and the explanation.
private struct UnitBlock: View {
    @Environment(AppStore.self) private var store
    let unit: Work.Unit
    let repo: Work.Repo?
    let folder: String
    let session: Session
    let summary: ProductSummary?
    let isOpen: Bool
    let toggle: () -> Void
    @State private var areRequestsShown = false
    @State private var compare: Compare?
    @State private var error: String?
    @State private var preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) { header.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(isOpen ? "Fold" : "Open: commits, requests, what it means for users")
            if isOpen {
                commits
                files
                if case .now = unit.kind, let repo, let next = Work.nextStep(repo) {
                    Text(next).font(.caption).foregroundStyle(Tokens.need).fixedSize(horizontal: false, vertical: true)
                }
                deployLine
                requests
                if let summary {
                    SummaryView(summary: summary, preview: preview)
                } else {
                    explainButton
                }
                if let error { Text(error).font(.caption).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isPending ? Tokens.needTint : Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 10))
        .task(id: isOpen) { if isOpen, preview == nil { preview = await store.previewURL(of: session) } }
        .sheet(isPresented: Binding(get: { compare != nil }, set: { if !$0 { compare = nil } })) {
            if let compare, let repo { DiffViewer(title: compare.title, sources: compare.sources(in: repo.path), selected: compare.selected) }
        }
    }

    // MARK: Header — "Sent to GitHub · 11:53 · 2 commits to master", then what it was

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Tokens.textDim).frame(width: 10)
                Text(kicker).font(Fonts.ui(11, weight: .bold)).tracking(0.6)
                    .foregroundStyle(isPending ? Tokens.need : Tokens.work).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(unit.title(in: repo)).font(Fonts.ui(14, weight: .semibold)).lineLimit(isOpen ? 3 : 1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 16)
        }
    }

    /// NOW with something to commit or push — not only questions asked since the last push.
    private var isPending: Bool {
        guard case .now = unit.kind, let repo else { return false }
        return !Work.pending([repo]).isEmpty
    }

    private var kicker: String {
        let requests = unit.runs.isEmpty ? nil : "\(unit.runs.count) request\(unit.runs.count == 1 ? "" : "s")"
        switch unit.kind {
        case .sent(let send):
            let count = "\(send.commits.count) commit\(send.commits.count == 1 ? "" : "s") to \(repo?.upstreamBranch ?? "")"
            return ["Sent to \(repo?.host ?? "the remote")", Work.when(send.at), count].joined(separator: " · ").uppercased()
        case .committed(let commit):
            return ["Committed", Work.when(commit.date), repo?.hasRemote == true ? "not sent" : nil].compactMap { $0 }
                .joined(separator: " · ").uppercased()
        case .now:
            let pending = repo.map { Work.pending([$0]) } ?? []
            // Requests since the last push that changed nothing git sees (questions, checks): nothing waits to be sent.
            guard !pending.isEmpty else { return ["Nothing to send", requests].compactMap { $0 }.joined(separator: " · ").uppercased() }
            return (["Not sent yet"] + pending).joined(separator: " · ").uppercased()
        case .requests:
            return "\(unit.runs.count) request\(unit.runs.count == 1 ? "" : "s") this week".uppercased()
        }
    }

    // MARK: Open — commits, files, CI, requests

    /// Every commit: feat and fix bright, the rest dim — never hidden (a chore can be a release).
    @ViewBuilder
    private var commits: some View {
        let commits = unit.commits(in: repo)
        if !commits.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(commits.prefix(8)) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(commit.sha.prefix(7)).font(Fonts.mono(10)).foregroundStyle(Tokens.textDim)
                        Text(commit.subject).font(.caption.weight(commit.isNotable ? .semibold : .regular))
                            .foregroundStyle(commit.isNotable ? Tokens.text : Tokens.textDim).lineLimit(2)
                    }
                    .help(commit.subject)
                }
                if commits.count > 8 { Text("and \(commits.count - 8) more").font(.caption).foregroundStyle(Tokens.textDim) }
            }
        }
    }

    /// "16 files · Compare": the whole unit side by side, file by file.
    @ViewBuilder
    private var files: some View {
        if let repo, let range = range(in: repo), range.files != 0 {
            HStack(spacing: 8) {
                if let count = range.files {
                    Text("\(count) file\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(Tokens.textDim)
                }
                Button("Compare") { openCompare(repo, old: range.old, new: range.new) }
                    .buttonStyle(PixelButtonStyle(compact: true))
                    .help("See every changed file, before and after")
                if case .now = unit.kind, !repo.uncommitted.isEmpty {
                    Button("Undo with rewind…") { askRewind() }
                        .buttonStyle(PixelButtonStyle(compact: true))
                        .help("Claude Code's /rewind: puts back what Claude edited, not what commands did")
                }
            }
        }
    }

    /// How many files (nil = not counted), the left side, the right side (nil = on disk). NOW compares what isn't
    /// committed — or, when everything is, the commits not pushed yet.
    private func range(in repo: Work.Repo) -> (files: Int?, old: String, new: String?)? {
        switch unit.kind {
        case .sent(let send): (send.files, send.from, send.to)
        case .committed(let commit): (nil, commit.sha + "^", commit.sha)
        case .now where repo.uncommitted.isEmpty && !repo.unsent.isEmpty: (nil, repo.upstream ?? "@{u}", "HEAD")
        case .now: (repo.uncommitted.count, "HEAD", nil)
        case .requests: nil
        }
    }

    private func openCompare(_ repo: Work.Repo, old: String, new: String?) {
        let (path, title) = (repo.path, unit.title(in: repo))
        Task {
            let files = await Task.detached { () -> (String, [GitPanel.FileChange]) in
                guard let new else { return ("HEAD", GitPanel.sourceControl(in: path).changes) }
                // A first commit has no parent: compare with git's empty tree.
                let left = GitService.output(["rev-parse", "--verify", "-q", old], in: path) ?? GitPanel.emptyTree
                return (left, GitPanel.files(between: left, and: new, in: path))
            }.value
            guard let first = files.1.first else { return }
            compare = Compare(title: title, files: files.1, selected: first.path, old: files.0, new: new)
        }
    }

    private func askRewind() {
        store.confirmation = PixelConfirmation(
            title: "Undo with Claude Code's rewind?",
            message: "Opens /rewind in this session's terminal: pick the point to go back to. It puts back what Claude edited. What shell commands did — installs, migrations, git — stays as it is.",
            action: "Open rewind",
            isDestructive: false
        ) { store.rewind(session.id!) }
    }

    /// The freshest push: where CI and deploy are with it.
    @ViewBuilder
    private var deployLine: some View {
        if case .sent(let send) = unit.kind, send == repo?.sends.last, let pipeline = store.pipeline(forRepo: repo?.path ?? ""),
           pipeline.sha == send.to || send.to.hasPrefix(pipeline.sha) {
            let summary = pipeline.summary
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "shippingbox").font(.system(size: 11))
                Text(summary.text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption).foregroundStyle(summary.needsYou ? Tokens.need : Tokens.textDim)
            .help("From CI — the CI panel has Run for a deploy that waits for you")
        }
    }

    /// The requests behind it and the gist of each answer, one click away.
    @ViewBuilder
    private var requests: some View {
        if !unit.runs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                // What isn't sent is still being made: its requests are always shown.
                let isOngoing = unit.kind == .now || unit.kind == .requests
                if isOngoing {
                    Text("YOUR REQUESTS, NEWEST FIRST").font(Fonts.ui(10, weight: .bold)).tracking(1).foregroundStyle(Tokens.textDim)
                } else {
                    Button { areRequestsShown.toggle() } label: {
                        Text("\(areRequestsShown ? "▾" : "▸") \(unit.runs.count) request\(unit.runs.count == 1 ? "" : "s") behind it")
                            .font(.caption.weight(.semibold)).foregroundStyle(Tokens.work)
                    }
                    .buttonStyle(.plain)
                }
                if areRequestsShown || isOngoing {
                    ForEach(unit.runs.reversed()) { RequestRow(run: $0) }
                }
            }
        }
    }

    @ViewBuilder
    private var explainButton: some View {
        let isWorking = store.explainingUnits.contains(unit.key)
        // Claude is still on one of its requests. A request left open by a session that isn't working (Esc,
        // then nothing) doesn't hold Explain back for good.
        let isRunning = unit.runs.contains { !$0.isDone && store.workingSessionIds.contains($0.sessionId) }
        VStack(alignment: .leading, spacing: 6) {
            Button(isWorking ? "Writing…" : "Explain for users") {
                Task {
                    do { try await store.explain(unit, in: folder, repo: repo); error = nil } catch { self.error = error.localizedDescription }
                }
            }
            .buttonStyle(PixelButtonStyle(isPrimary: true))
            .disabled(isWorking || isRunning)
            Text(isRunning
                 ? "Available when Claude finishes the request it's on."
                 : "What your users will notice, section by section, what to check and how to try it. Claude reads only the commits, your requests and its answers — a small request, not the whole conversation again.")
                .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "11:44 “давай импорт графика из Excel” → Импорт графика займа из Excel готов."
private struct RequestRow: View {
    let run: Run

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(run.startedAt, format: .dateTime.hour().minute()).font(Fonts.mono(10)).foregroundStyle(Tokens.textDim)
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(Notifier.plainText(run.request, limit: 140))”").font(.caption.weight(.semibold)).lineLimit(2)
                if let line = outcome {
                    Text(line.text).font(.caption).foregroundStyle(line.color).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .help(run.request)
    }

    private var outcome: (text: String, color: Color)? {
        switch run.outcome {
        case .working: return ("working…" + (run.gist.map { " " + $0 } ?? ""), Tokens.work)
        case .askedYou: return ("Asks: " + (run.question ?? ""), Tokens.need)
        case .done: return run.gist.map { (text: "→ " + $0, color: Tokens.textDim) }
        case .noReply: return ("no reply of its own — the next message, Esc, an error or the session closing came first", Tokens.textDim)
        }
    }
}

/// The explanation: headline, the changes by section of the product, what to check, how to try.
private struct SummaryView: View {
    let summary: ProductSummary
    let preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.headline).font(Fonts.ui(17, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            ForEach(sections, id: \.name) { section in
                VStack(alignment: .leading, spacing: 5) {
                    if !section.name.isEmpty {
                        Text(section.name.uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.textDim)
                    }
                    ForEach(Array(section.changes.enumerated()), id: \.offset) { _, change in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(change.kind.uppercased()).font(Fonts.ui(10, weight: .bold)).tracking(0.8)
                                    .foregroundStyle(change.kind == "removed" ? Tokens.need : Tokens.work)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Tokens.workTint, in: Capsule())
                                Text(change.what).fixedSize(horizontal: false, vertical: true)
                            }
                            let place = change.where_.components(separatedBy: "→").dropFirst()
                                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " → ")
                            if !place.isEmpty { Text(place).font(.caption).foregroundStyle(Tokens.textDim).padding(.leading, 2) }
                        }
                    }
                }
            }
            if !summary.check.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CHECK BEFORE YOU SHIP").font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.need)
                    ForEach(Array(summary.check.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            SelectionRing(kind: .waiting, size: 6)
                            Text(item).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.needTint, in: RoundedRectangle(cornerRadius: 10))
            }
            if !summary.howToTry.isEmpty || preview != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HOW TO TRY").font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.textDim)
                    if !summary.howToTry.isEmpty { Text(summary.howToTry).fixedSize(horizontal: false, vertical: true) }
                    if let preview {
                        Button("Open preview · \(preview.port.map(String.init) ?? "")") { NSWorkspace.shared.open(preview) }
                            .buttonStyle(PixelButtonStyle(compact: true))
                            .help("Something is listening in this session's own ports")
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Changes grouped by the section of the product they're in, in the order Claude named them.
    private var sections: [(name: String, changes: [ProductSummary.Change])] {
        var order: [String] = []
        var groups: [String: [ProductSummary.Change]] = [:]
        for change in summary.changes {
            if groups[change.section] == nil { order.append(change.section) }
            groups[change.section, default: []].append(change)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

/// What changed on its own, over the window — Today's click when the panel isn't in the layout.
struct WhatChangedSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What changed").font(Fonts.title(22))
                if let session = store.selectedSession {
                    Text(store.project(for: session)?.name ?? "").font(Fonts.ui(15, weight: .semibold)).foregroundStyle(Tokens.textDim)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
            }
            ScrollView { WhatChangedPanel().frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(20)
        .frame(width: 560, height: 640)
        .paperSheet()
    }
}
