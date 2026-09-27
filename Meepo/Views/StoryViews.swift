import SwiftUI

/// A session's events in plain words, newest first. A line opens to show everything the event said; a file
/// it touched opens in the editor.
struct EventStoryList: View {
    let events: [HookEvent]
    var limit: Int?
    @State private var openLine: Int64?
    @State private var openFile: String?

    var body: some View {
        let lines = EventStory.lines(events)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(limit.map { Array(lines.prefix($0)) } ?? lines) { line in row(line) }
        }
        .sheet(isPresented: Binding(get: { openFile != nil }, set: { if !$0 { openFile = nil } })) {
            if let openFile { FileViewer(root: "", path: openFile) }
        }
    }

    private func row(_ line: EventStory.Line) -> some View {
        let isOpen = openLine == line.id
        return VStack(alignment: .leading, spacing: 4) {
            Button { openLine = isOpen ? nil : line.id } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: line.icon).font(.system(size: 11)).frame(width: 14)
                        .foregroundStyle(line.isFailure ? Tokens.danger : line.needsYou ? Tokens.need : Tokens.textDim)
                    Text(line.title).font(Fonts.ui(13, weight: line.needsYou ? .semibold : .regular))
                        .foregroundStyle(line.isFailure ? Tokens.danger : line.isRunning ? Tokens.work : line.isQuiet ? Tokens.textDim : Tokens.text)
                        .lineLimit(isOpen ? nil : 1)
                    Spacer(minLength: 4)
                    Text(line.date, format: .dateTime.hour().minute()).font(Fonts.mono(10)).foregroundStyle(Tokens.textDim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click for details")
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = line.detail {
                        Text(detail).font(Fonts.mono(11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let file = line.file {
                        Button("Open \(URL(filePath: file).lastPathComponent)") { openFile = file }
                            .buttonStyle(PixelButtonStyle(compact: true))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 8))
                .padding(.leading, 21)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Home → Today: what was sent today, project by project, and what's left. A row is a push; ▸ shows the requests
/// behind it and the gist of each answer. A click opens the session with What changed on that push.
struct TodayList: View {
    @Environment(AppStore.self) private var store
    let sessions: [Session]
    @State private var open: Set<String> = []

    /// A row: one unit of work of one folder.
    struct Row: Identifiable {
        let unit: Work.Unit
        let repo: Work.Repo?
        let folder: String
        var id: String { folder + "#" + unit.id }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let start = Calendar.current.startOfDay(for: context.date)
            let projects = store.projects.compactMap { project -> (Project, [Row], [String])? in
                let rows = Self.rows(of: sessions.filter { $0.projectId == project.id }, store: store, since: start)
                let left = Self.left(project, rows: rows, store: store)
                return rows.isEmpty && left.isEmpty ? nil : (project, rows, left)
            }
            let all = projects.flatMap(\.1)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.header(all, since: start, now: context.date)).font(Fonts.ui(15, weight: .semibold))
                    ForEach(projects.flatMap { project, _, left in left.map { "\($0) (\(project.name))" } }, id: \.self) { line in
                        Text(line).foregroundStyle(Tokens.need)
                    }
                }
                ForEach(projects, id: \.0.id) { project, rows, _ in
                    projectBlock(project, rows: rows, now: context.date)
                }
            }
        }
    }

    /// "Today: 3 sent · 20 requests · Claude worked 1h 13m".
    static func header(_ rows: [Row], since start: Date, now: Date) -> String {
        let sent = rows.filter { if case .sent = $0.unit.kind { true } else { false } }.count
        let runs = rows.flatMap(\.unit.runs).filter { $0.startedAt >= start }
        guard sent > 0 || !runs.isEmpty else { return "Nothing sent or asked yet today." }
        let worked = PipelineView.duration(runs.reduce(0) { $0 + $1.worked(now: now) })
        return "Today: \(sent) sent · \(runs.count) request\(runs.count == 1 ? "" : "s") · Claude worked \(worked)"
    }

    /// Today's units of every folder these sessions work in: pushes (or commits) made today, and what isn't sent.
    static func rows(of sessions: [Session], store: AppStore, since start: Date) -> [Row] {
        var folders: [String] = []
        for session in sessions { if let folder = store.workdir(of: session), !folders.contains(folder) { folders.append(folder) } }
        return folders.flatMap { folder -> [Row] in
            guard let work = store.work[folder], work.isGitRead else { return [] }
            let repos: [Work.Repo?] = work.repos.isEmpty ? [nil] : work.repos
            return repos.flatMap { repo in
                Work.units(repo, runs: repo.map { Work.runs(work.runs, for: $0, in: work.repos) } ?? work.runs).compactMap { unit -> Row? in
                    let today: Bool = switch unit.kind {
                    case .sent, .committed: unit.date >= start
                    case .now: unit.runs.contains { $0.startedAt >= start } || !(repo.map { Work.pending([$0]) } ?? []).isEmpty
                    case .requests: unit.runs.contains { $0.startedAt >= start }
                    }
                    return today ? Row(unit: unit, repo: repo, folder: folder) : nil
                }
            }
        }
    }

    /// What's left in a project: what isn't sent, CI waiting on the user, a question Claude ended on.
    static func left(_ project: Project, rows: [Row], store: AppStore) -> [String] {
        var repos: [Work.Repo] = []
        for repo in rows.compactMap(\.repo) where !repos.contains(where: { $0.path == repo.path }) { repos.append(repo) }
        var left = Work.pending(repos)
        if let pipeline = project.id.flatMap({ store.pipelines[$0] }) {
            if pipeline.steps.contains(where: { $0.state == .failed }) { left.append("CI failed") }
            if let ready = pipeline.steps.first(where: { $0.state == .manual && pipeline.canStart($0) }) {
                left.append("\(ready.name) waiting for your click")
            }
        }
        // Each session's last request: did it end on a question?
        let last = Dictionary(rows.flatMap(\.unit.runs).map { ($0.sessionId, $0) }) { $0.startedAt > $1.startedAt ? $0 : $1 }
        for question in last.values.sorted(by: { $0.startedAt < $1.startedAt }).compactMap(\.question) {
            left.append("Asked you: “\(Notifier.plainText(question, limit: 80))”")
        }
        return left
    }

    private func projectBlock(_ project: Project, rows: [Row], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.name).font(Fonts.ui(15, weight: .bold))
            ForEach(rows) { row in rowView(row, project: project, now: now) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokens.line))
    }

    private func rowView(_ row: Row, project: Project, now: Date) -> some View {
        let isOpen = open.contains(row.id)
        let count = row.unit.runs.count
        let pending = row.repo.map { Work.pending([$0]) } ?? []
        let (badge, color, time): (String, Color, String?) = switch row.unit.kind {
        case .sent(let send): ("SENT", Tokens.work, send.at.formatted(date: .omitted, time: .shortened))
        case .committed(let commit): ("COMMITTED", Tokens.work, commit.date.formatted(date: .omitted, time: .shortened))
        case .now where !pending.isEmpty: ("NOT SENT", Tokens.need, nil)
        case .now, .requests: ("ASKED", Tokens.textDim, nil)
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(time ?? "now").font(Fonts.mono(11)).foregroundStyle(Tokens.textDim).frame(width: 44, alignment: .leading)
                Text(badge).font(Fonts.ui(10, weight: .bold)).tracking(0.8).foregroundStyle(color)
                    .lineLimit(1).frame(width: 70, alignment: .leading) // the titles line up whatever the badge
                Button { openInSession(row, project: project) } label: {
                    Text(title(row, pending: pending, count: count)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the session and What changed for this")
                if count > 0 {
                    Button(isOpen ? "▾" : "▸") { if isOpen { open.remove(row.id) } else { open.insert(row.id) } }
                        .buttonStyle(.plain).foregroundStyle(Tokens.work)
                        .help(isOpen ? "Hide the requests" : "The requests behind it and what Claude answered")
                }
            }
            if isOpen {
                ForEach(row.unit.runs.reversed()) { run in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("“\(Notifier.plainText(run.request, limit: 120))”").font(.caption.weight(.semibold)).lineLimit(2)
                        if let answer = run.question.map({ "Asks: " + $0 }) ?? run.gist.map({ "→ " + $0 }) {
                            Text(answer).font(.caption).foregroundStyle(run.question == nil ? Tokens.textDim : Tokens.need).lineLimit(2)
                        }
                    }
                    .padding(.leading, 54)
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// "Импорт графика из Excel — 5 requests"; NOW: "Refunds for Kaspi — 4 files not committed · 2 requests".
    private func title(_ row: Row, pending: [String], count: Int) -> String {
        let requests = count == 0 ? [] : ["\(count) request\(count == 1 ? "" : "s")"]
        let about = (row.unit.kind == .now ? pending : []) + requests
        return ([row.unit.title(in: row.repo)] + (about.isEmpty ? [] : [about.joined(separator: " · ")])).joined(separator: " — ")
    }

    /// The session that made it (its last request's), else one working in that folder; What changed shows it.
    private func openInSession(_ row: Row, project: Project) {
        let id = row.unit.runs.last?.sessionId
            ?? sessions.first { store.workdir(of: $0) == row.folder }?.id
            ?? sessions.first { $0.projectId == project.id }?.id
        guard let id else { return }
        store.selectedSessionId = id
        store.focusedUnit = AppStore.FocusedUnit(folder: row.folder, unit: row.unit.id)
        if store.shell.zone(of: .product) == nil { store.isWhatChangedShown = true }
    }
}
