import SwiftUI
import WidgetKit

/// Desktop widget (SPEC module 13): tokens today, sessions running, sessions waiting for the user.
@main
struct MeepoWidget: Widget {
    init() { Fonts.register() }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MeepoWidget", provider: Provider()) { entry in
            MeepoWidgetView(snapshot: entry.snapshot)
                .containerBackground(Tokens.grass, for: .widget)
        }
        .configurationDisplayName("Meepo")
        .description("Tokens today, running and waiting sessions.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// Meepo reloads the timeline when the numbers change; the 15-minute refresh is only a fallback.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: WidgetSnapshot(tokensToday: 1_240_000, activeSessions: 3, waitingSessions: 1, updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Entry(date: .now, snapshot: WidgetSnapshot.read() ?? WidgetSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: .now, snapshot: WidgetSnapshot.read() ?? WidgetSnapshot())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct MeepoWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("meepo").font(Fonts.title(16)).foregroundStyle(Tokens.text)
            if family == .systemMedium {
                HStack(spacing: 16) { tokens; sessions }
            } else {
                tokens
                sessions
            }
            Spacer(minLength: 0)
            if snapshot.isStale() {
                Text("Meepo isn't running").font(.caption2).foregroundStyle(Tokens.textDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A stale file (Meepo crashed or was force-quit) or yesterday's total says nothing about now.
    private var tokens: some View {
        let known = !snapshot.isStale() && Calendar.current.isDateInToday(snapshot.updatedAt)
        return VStack(alignment: .leading, spacing: 0) {
            Text(known ? TokenFormat.short(snapshot.tokensToday) : "–").font(Fonts.mono(22)).foregroundStyle(Tokens.screen)
            Text("tokens today").font(.caption2).foregroundStyle(Tokens.textDim)
        }
    }

    private var sessions: some View {
        let stale = snapshot.isStale()
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(stale ? "–" : String(snapshot.activeSessions)).font(Fonts.mono(18))
                    .foregroundStyle(stale ? Tokens.textDim : Tokens.selection)
                Text("running").font(.caption2).foregroundStyle(Tokens.textDim)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(stale ? "–" : String(snapshot.waitingSessions)).font(Fonts.mono(18))
                    .foregroundStyle(!stale && snapshot.waitingSessions > 0 ? Tokens.alert : Tokens.textDim)
                Text("waiting").font(.caption2).foregroundStyle(Tokens.textDim)
            }
        }
    }
}
