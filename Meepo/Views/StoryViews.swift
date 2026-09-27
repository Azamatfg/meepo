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
                        .foregroundStyle(line.isFailure ? Tokens.danger : line.isRunning ? Tokens.work : Tokens.text)
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

/// Home → Today: every request of the day by session — what was asked, how long Claude worked, what came of it.
/// A click opens that session.
struct TodayList: View {
    @Environment(AppStore.self) private var store
    let sessions: [Session]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            // One read: today's events of every session.
            let today = Dictionary(grouping: Runs.from(store.events(since: Calendar.current.startOfDay(for: context.date))),
                                   by: \.sessionId)
            let days = sessions.map { session in (session, (today[session.id!] ?? []).reversed() as [Run]) }
            let runs = days.flatMap(\.1)
            VStack(alignment: .leading, spacing: 14) {
                if runs.isEmpty {
                    Text("Nothing asked yet today.").foregroundStyle(Tokens.textDim)
                } else {
                    Text(Self.totals(runs, now: context.date)).foregroundStyle(Tokens.textDim)
                }
                ForEach(days.filter { !$0.1.isEmpty }, id: \.0.id) { session, runs in
                    sessionBlock(session, runs: runs, now: context.date)
                }
            }
        }
    }

    /// "Claude worked 1h 12m today on 9 requests; 3 ended with a question for you."
    static func totals(_ runs: [Run], now: Date) -> String {
        let worked = PipelineView.duration(runs.reduce(0) { $0 + $1.worked(now: now) })
        let asked = runs.filter { $0.outcome == .askedYou }.count
        return "Claude worked \(worked) today on \(runs.count) request\(runs.count == 1 ? "" : "s")"
            + (asked == 0 ? "." : "; \(asked) ended with a question for you.")
    }

    private func sessionBlock(_ session: Session, runs: [Run], now: Date) -> some View {
        let look = store.look(of: session)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                SelectionRing(kind: look.ring)
                Text(store.project(for: session)?.name ?? "?").font(Fonts.ui(15, weight: .bold))
                Text(store.displayName(of: session)).font(.caption).foregroundStyle(Tokens.textDim).lineLimit(1)
            }
            ForEach(runs) { run in
                Button { store.selectedSessionId = session.id } label: { runRow(run, now: now) }
                    .buttonStyle(.plain)
                    .help("Open this session")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokens.line))
    }

    private func runRow(_ run: Run, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(run.startedAt, format: .dateTime.hour().minute()).font(Fonts.mono(11)).foregroundStyle(Tokens.textDim)
            VStack(alignment: .leading, spacing: 2) {
                Text(Notifier.plainText(run.request, limit: 120)).lineLimit(2)
                Text(["worked " + PipelineView.duration(run.worked(now: now)),
                      run.files.isEmpty ? nil : "\(run.files.count) file\(run.files.count == 1 ? "" : "s") changed"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Tokens.textDim)
            }
            Spacer(minLength: 6)
            switch run.outcome {
            case .working: Text("working…").font(.caption.weight(.semibold)).foregroundStyle(Tokens.work)
            case .askedYou: Text("asked you").font(.caption.weight(.semibold)).foregroundStyle(Tokens.need)
            case .done: Text("done").font(.caption.weight(.semibold)).foregroundStyle(Tokens.textDim)
            case .stopped: Text("stopped").font(.caption.weight(.semibold)).foregroundStyle(Tokens.textDim)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
