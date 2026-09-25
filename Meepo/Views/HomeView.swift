import SwiftUI

/// The Home tab: every session at a glance — as cards (Deck) or as lanes over the last hour (Timeline).
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("homeView") private var mode = "deck"

    var body: some View {
        let sessions = store.orderedSessions
        let working = sessions.filter { store.look(of: $0).ring == .working }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    (Text("\(working) working. ")
                        + Text(store.waitingCount == 0 ? "Nobody is waiting." : "\(store.waitingCount) need\(store.waitingCount == 1 ? "s" : "") you.")
                        .foregroundColor(store.waitingCount == 0 ? Tokens.text : Tokens.need))
                        .font(Fonts.ui(36, weight: .bold))
                    Text("\(TokenFormat.short(store.sessionUsage.values.reduce(0) { $0 + $1.tokensToday })) tokens today across \(sessions.count) sessions")
                        .foregroundStyle(Tokens.textDim)
                }
                HStack(spacing: 2) {
                    ForEach([("deck", "Deck"), ("timeline", "Timeline")], id: \.0) { key, title in
                        Button(title) { mode = key }
                            .buttonStyle(.plain)
                            .font(Fonts.ui(13, weight: .semibold))
                            .foregroundStyle(mode == key ? Tokens.text : Tokens.textDim)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(mode == key ? Tokens.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(3)
                .background(Tokens.ghost, in: RoundedRectangle(cornerRadius: 10))
                if sessions.isEmpty {
                    Text("No sessions yet — start one with + above.").foregroundStyle(Tokens.textDim)
                } else if mode == "timeline" {
                    TimelineLanes(sessions: sessions)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(sessions) { SessionCard(session: $0) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A session as a card: state, project and branch, what it's doing, its stage on the workflow.
private struct SessionCard: View {
    @Environment(AppStore.self) private var store
    let session: Session

    var body: some View {
        let look = store.look(of: session)
        let isWaiting = look.ring == .waiting
        Button { store.selectedSessionId = session.id } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SelectionRing(kind: look.ring, size: 9)
                    Text(store.project(for: session)?.name ?? "?").font(Fonts.ui(19, weight: .bold)).lineLimit(1)
                    Text(session.worktreeName.map { "worktree \($0)" } ?? session.branch ?? "").font(Fonts.mono(12))
                        .foregroundStyle(Tokens.textDim).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(look.text.uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1)
                        .foregroundStyle(isWaiting ? Tokens.need : look.ring == .working ? Tokens.work : Tokens.textDim)
                        .lineLimit(1)
                }
                Text(lastLine)
                    .font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                    .padding(10)
                    .background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 10))
                StageProgress(current: session.stage, isWaiting: isWaiting)
            }
            .padding(16)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(isWaiting ? Tokens.need : Tokens.line, lineWidth: isWaiting ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { SessionMenu(session: session) }
    }

    /// The latest hook event with text, else the model — never an invented line.
    private var lastLine: String {
        let latest = store.events(since: .now.addingTimeInterval(-24 * 3600))
            .last { $0.sessionId == session.id && !($0.summary ?? "").isEmpty }
        return latest.flatMap(\.summary).map { Notifier.plainText($0, limit: 200) }
            ?? [session.stage?.uppercased(), session.model].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The workflow as thin segments: done ones in blue, the current one orange when it waits for you.
private struct StageProgress: View {
    @Environment(AppStore.self) private var store
    let current: String?
    let isWaiting: Bool

    var body: some View {
        let stages = store.stages
        let index = stages.firstIndex { $0.name == current }
        HStack(spacing: 5) {
            ForEach(Array(stages.enumerated()), id: \.element.id) { i, stage in
                let done = index.map { i < $0 } ?? false
                let now = i == index
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(done ? Tokens.work : now ? (isWaiting ? Tokens.need : Tokens.work.opacity(0.45)) : Tokens.line)
                        .frame(height: 4)
                    Text(stage.label).font(Fonts.ui(10, weight: .bold)).tracking(0.8)
                        .foregroundStyle(done || now ? Tokens.text : Tokens.textDim)
                }
            }
        }
    }
}

/// One lane per session over the last hour, a cell per minute: blue when it worked, orange when it waited
/// for you, empty when nothing happened. Built from the hook events Meepo already keeps.
private struct TimelineLanes: View {
    @Environment(AppStore.self) private var store
    let sessions: [Session]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let start = context.date.addingTimeInterval(-3600)
            let events = store.events(since: start)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sessions) { session in
                    lane(session, cells: Self.cells(events.filter { $0.sessionId == session.id }, start: start))
                }
                HStack {
                    Text("60 min ago"); Spacer(); Text("30 min"); Spacer(); Text("now")
                }
                .font(Fonts.ui(11)).foregroundStyle(Tokens.textDim)
                .padding(.leading, 212)
            }
        }
    }

    private func lane(_ session: Session, cells: [Cell]) -> some View {
        let look = store.look(of: session)
        return Button { store.selectedSessionId = session.id } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        SelectionRing(kind: look.ring)
                        Text(store.project(for: session)?.name ?? "?").font(Fonts.ui(15, weight: .bold)).lineLimit(1)
                    }
                    Text(look.text).font(.caption).foregroundStyle(look.ring == .waiting ? Tokens.need : Tokens.textDim)
                        .lineLimit(1).padding(.leading, 15)
                }
                .frame(width: 200, alignment: .leading)
                HStack(spacing: 2) {
                    ForEach(cells.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(cells[i] == .waiting ? Tokens.need : cells[i] == .working ? Tokens.work.opacity(0.55) : Tokens.line.opacity(0.5))
                            .frame(height: 26)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokens.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    enum Cell { case empty, working, waiting }

    /// 60 one-minute cells; waiting wins over working within a minute.
    static func cells(_ events: [HookEvent], start: Date) -> [Cell] {
        var cells = [Cell](repeating: .empty, count: 60)
        for event in events {
            let minute = Int(event.createdAt.timeIntervalSince(start) / 60)
            guard cells.indices.contains(minute) else { continue }
            let waits = event.name == "PermissionRequest" || event.name == "Notification"
            if waits { cells[minute] = .waiting } else if cells[minute] == .empty { cells[minute] = .working }
        }
        return cells
    }
}
