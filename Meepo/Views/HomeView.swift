import SwiftUI

/// The Home tab: every session at a glance — as cards (Deck) or as the day's requests (Today).
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
                if !store.claudeNews.isEmpty { ClaudeNewsCard() }
                if let noticed = store.visibleSuggestions.first { NoticedRow(suggestion: noticed, isCard: true) }
                HStack(spacing: 2) {
                    ForEach([("deck", "Deck"), ("today", "Today")], id: \.0) { key, title in
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
                .overlay(alignment: .trailing) { InfoButton(title: "Home", text: Explain.home).offset(x: 26) }
                if sessions.isEmpty {
                    Text("No sessions yet — start one with + above.").foregroundStyle(Tokens.textDim)
                } else if mode != "deck" {
                    TodayList(sessions: sessions)
                } else {
                    // One read for every card: the last day's events, grouped by session.
                    let events = Dictionary(grouping: store.events(since: .now.addingTimeInterval(-24 * 3600)), by: \.sessionId)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(sessions) { session in
                            let own = events[session.id!] ?? []
                            SessionCard(session: session, run: Runs.from(own).last, now: own.last.flatMap(EventStory.line(for:)))
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A session as a card: state, what was asked last, what Claude is doing now in plain words, what it changed.
private struct SessionCard: View {
    @Environment(AppStore.self) private var store
    let session: Session
    /// The latest request of the last day, and the latest step in plain words.
    let run: Run?
    let now: EventStory.Line?

    var body: some View {
        let look = store.look(of: session)
        let isWaiting = look.ring == .waiting
        Button { store.selectedSessionId = session.id } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SelectionRing(kind: look.ring, size: 9)
                    Text(store.project(for: session)?.name ?? "?").font(Fonts.ui(19, weight: .bold)).lineLimit(1)
                    Text(store.displayName(of: session)).font(Fonts.ui(14))
                        .foregroundStyle(Tokens.textDim).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(look.text.uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1)
                        .foregroundStyle(isWaiting ? Tokens.need : look.ring == .working ? Tokens.work : Tokens.textDim)
                        .lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(run.map { "“\(Notifier.plainText($0.request, limit: 140))”" } ?? "Nothing asked yet")
                        .font(Fonts.ui(14, weight: .semibold)).lineLimit(2)
                        .foregroundStyle(run == nil ? Tokens.textDim : Tokens.text)
                    if let now {
                        HStack(spacing: 6) {
                            Image(systemName: now.icon).font(.system(size: 11))
                            Text((look.ring == .working ? "Now: " : "Last: ") + now.title).lineLimit(1)
                        }
                        .font(.caption).foregroundStyle(isWaiting ? Tokens.need : look.ring == .working ? Tokens.work : Tokens.textDim)
                    }
                    if let run {
                        Text(["started " + run.startedAt.formatted(date: .omitted, time: .shortened),
                              "worked " + PipelineView.duration(run.worked()),
                              run.files.isEmpty ? nil : "\(run.files.count) file\(run.files.count == 1 ? "" : "s") changed"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Tokens.textDim)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                .padding(10)
                .background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(16)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(isWaiting ? Tokens.need : Tokens.line, lineWidth: isWaiting ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { SessionMenu(session: session) }
    }


}

/// "Claude Code 2.1.281 → 2.1.282": what changed, the lines that touch this setup first. From the changelog
/// Claude Code keeps locally; "Got it" makes this version the new baseline.
private struct ClaudeNewsCard: View {
    @Environment(AppStore.self) private var store
    @State private var isAllShown = false

    var body: some View {
        let items = store.claudeNews.flatMap(\.items)
        let sorted = ClaudeChangelog.relevantFirst(items, keywords: store.claudeNewsKeywords())
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("NEW IN CLAUDE CODE").font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.work)
                Text("\(store.claudeNewsSince ?? "") → \(store.claudeVersion ?? "")").font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
                Spacer()
                Button("All \(items.count) changes") { isAllShown = true }.buttonStyle(PixelButtonStyle(compact: true))
                Button("Got it") { store.acknowledgeClaudeNews() }.buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
            }
            if sorted.relevant.isEmpty {
                Text("Nothing here touches hooks, permissions, skills, effort or the rest of your setup.")
                    .foregroundStyle(Tokens.textDim)
            } else {
                Text("Touches your setup").font(Fonts.ui(15, weight: .bold))
                ForEach(Array(sorted.relevant.prefix(5).enumerated()), id: \.offset) { _, line in
                    Text("• " + Self.plain(line)).fixedSize(horizontal: false, vertical: true)
                }
                if sorted.relevant.count > 5 {
                    Text("and \(sorted.relevant.count - 5) more").foregroundStyle(Tokens.textDim)
                }
            }
        }
        .padding(18)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Tokens.line))
        .sheet(isPresented: $isAllShown) { ClaudeNewsSheet(sorted: sorted) }
    }

    /// Changelog lines use Markdown backticks; show them as plain text.
    static func plain(_ line: String) -> String { line.replacingOccurrences(of: "`", with: "") }
}

private struct ClaudeNewsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let sorted: (relevant: [String], other: [String])

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude Code \(store.claudeNewsSince ?? "") → \(store.claudeVersion ?? "")").font(Fonts.title(22))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !sorted.relevant.isEmpty {
                        Text("TOUCHES YOUR SETUP").font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.work)
                        ForEach(Array(sorted.relevant.enumerated()), id: \.offset) { Text("• " + ClaudeNewsCard.plain($1)) }
                    }
                    Text("EVERYTHING ELSE").font(Fonts.ui(11, weight: .bold)).tracking(1.2).foregroundStyle(Tokens.textDim)
                        .padding(.top, 8)
                    ForEach(Array(sorted.other.enumerated()), id: \.offset) { Text("• " + ClaudeNewsCard.plain($1)).foregroundStyle(Tokens.textDim) }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 720, height: 640)
        .paperSheet()
    }
}
