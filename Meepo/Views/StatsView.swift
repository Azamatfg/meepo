import SwiftUI

/// Token usage of every Claude Code session on this Mac: today / this week, by project and by model.
struct StatsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var period = Period.today

    enum Period: String, CaseIterable { case today = "Today", week = "Week" }

    var body: some View {
        let stats = store.usageStats(since: start)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("STATS").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                Spacer()
                ForEach(Period.allCases, id: \.self) { p in
                    Button(p.rawValue) { period = p }
                        .buttonStyle(PixelButtonStyle())
                        .overlay { if p == period { Bevel(raised: false) } }
                }
                Button("Close") { dismiss() }
                    .buttonStyle(PixelButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(TokenFormat.short(stats.total.total))
                    .font(Fonts.mono(28).bold())
                    .foregroundStyle(Tokens.selection)
                Text("tokens").foregroundStyle(Tokens.textDim)
            }
            UsageTable(title: "By project", rows: stats.byProject)
            UsageTable(title: "By model", rows: stats.byModel)
        }
        .padding(16)
        .frame(width: 640)
        .frame(minHeight: 420, alignment: .top)
        .background(Tokens.grass)
        .pixelFrame(6)
        .preferredColorScheme(.dark)
    }

    private var start: Date {
        let today = Calendar.current.startOfDay(for: .now)
        return period == .today ? today : Calendar.current.date(byAdding: .day, value: -6, to: today)!
    }
}

private struct UsageTable: View {
    let title: String
    let rows: [(name: String, totals: AppStore.UsageTotals)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(Fonts.title(16)).foregroundStyle(Tokens.text)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(["input", "output", "cache write", "cache read", "total"], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(Tokens.textDim)
                    }
                }
                if rows.isEmpty {
                    GridRow { Text("No usage yet").foregroundStyle(Tokens.textDim).gridCellColumns(6) }
                }
                ForEach(rows, id: \.name) { row in
                    GridRow {
                        Text(row.name).foregroundStyle(Tokens.text).lineLimit(1)
                        ForEach([row.totals.input, row.totals.output, row.totals.cacheWrite, row.totals.cacheRead], id: \.self) {
                            Text(TokenFormat.short($0)).font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
                        }
                        Text(TokenFormat.short(row.totals.total)).font(Fonts.mono(12)).foregroundStyle(Tokens.text)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.dirt)
            .sunken()
        }
    }
}

/// Settings: context window per model (Claude Code doesn't write it into the transcript).
struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let models = store.recentModels()
        VStack(alignment: .leading, spacing: 10) {
            Text("SETTINGS").font(Fonts.title(18)).foregroundStyle(Tokens.text)
            Text("Context window per model — Claude Code doesn't record it, so the context bar needs it.")
                .font(.caption)
                .foregroundStyle(Tokens.textDim)
            if models.isEmpty {
                Text("No models used yet").foregroundStyle(Tokens.textDim)
            }
            ForEach(models, id: \.self) { model in
                FieldRow(model) {
                    PixelMenu(selection: store.contextWindow(for: model) == 1_000_000 ? "1M" : "200K") {
                        Button("200K") { store.contextWindows[model] = 200_000 }
                        Button("1M") { store.contextWindows[model] = 1_000_000 }
                    }
                }
                .font(Fonts.mono(13))
            }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .background(Tokens.grass)
        .pixelFrame(6)
        .preferredColorScheme(.dark)
    }
}
