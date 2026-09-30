import SwiftUI

/// Token usage of every Claude Code session on this Mac: today / this week / all time, by project and by model.
struct StatsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var period = Period.today
    /// Counted when the period changes, not on every hook event that redraws the sheet (All time: two ~14 ms queries).
    @State private var stats = AppStore.UsageStats()
    @State private var since: Date?

    enum Period: String, CaseIterable {
        case today = "Today", week = "Week", all = "All time"

        func start(now: Date = .now) -> Date {
            let today = Calendar.current.startOfDay(for: now)
            return switch self {
            case .today: today
            case .week: Calendar.current.date(byAdding: .day, value: -6, to: today)!
            case .all: .distantPast
            }
        }
    }

    var body: some View {
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
                if period == .all, let since {
                    Text("since \(since.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(Tokens.textDim)
                        .help("""
                            meepo's own count, from its first record. Claude Code deletes a conversation's transcript \
                            after 30 days by default (cleanupPeriodDays), so nothing older is left to count. Claude Code's /stats shows \
                            more: it keeps its own totals from before that, and one request is written as several transcript lines \
                            with the same usage, some of which it counts again; meepo counts each request once.
                            """)
                }
            }
            Text("Counts each API request once. Claude Code's /stats also keeps history from before these transcripts and can count one request more than once.")
                .font(.caption)
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    UsageTable(title: "By project", rows: stats.byProject)
                    UsageTable(title: "By model", rows: stats.byModel)
                }
            }
        }
        .padding(16)
        .frame(width: 640)
        .frame(minHeight: 420, maxHeight: 560, alignment: .top)
        .background(Tokens.grass)
        .pixelFrame(6)
        .task(id: period) {
            stats = store.usageStats(since: period.start())
            if period == .all { since = store.usageHistoryStart() }
        }
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

/// Settings: a sheet in the window (⌘,, the ≡ menu, the rail's gear).
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SETTINGS").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(PixelButtonStyle())
                    .keyboardShortcut(store.confirmation == nil ? .cancelAction : nil)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    FieldRow("Relay at context") {
                        PixelMenu(selection: "\(Int(store.relayThreshold * 100))%") {
                            ForEach([0.6, 0.7, 0.8, 0.9], id: \.self) { value in
                                Button("\(Int(value * 100))%") { store.relayThreshold = value }
                            }
                        }
                    }
                    Text("""
                        Context is how much of the conversation Claude holds in mind. When a session's context is this \
                        full, a RELAY button appears under its terminal. Nothing happens until you click it. Then Claude \
                        sums up the work, a fresh session carries on from that summary, and the old one closes. Why: \
                        longer sessions are more expensive even when cached. Claude Code's own alternative: /autocompact.
                        """)
                        .font(.caption)
                        .foregroundStyle(Tokens.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    FieldRow("Updates") {
                        HStack(spacing: 6) {
                            Button(store.autoUpdate ? "AUTO" : "OFF") { store.autoUpdate.toggle() }
                                .help("Download new versions in the background and install them when meepo quits")
                            PixelMenu(selection: store.updateChannel.rawValue.uppercased()) {
                                ForEach(Updater.Channel.allCases, id: \.self) { channel in
                                    Button(channel == .beta ? "Beta — newest, may have rough edges" : "Stable — releases only") {
                                        store.updateChannel = channel
                                    }
                                }
                            }
                            Button("CHECK NOW") { Task { await store.checkForUpdates(userInitiated: true) } }
                                .help("Same as `meepo update` in a terminal")
                        }
                        .buttonStyle(PixelButtonStyle())
                    }
                    FieldRow("Remote Control for new sessions") {
                        Button(store.remoteControlForNewSessions ? "ON" : "OFF") { store.remoteControlForNewSessions.toggle() }
                            .buttonStyle(PixelButtonStyle())
                            .help("claude --remote-control \"project · branch\": sessions show up in the Claude app and claude.ai (needs a claude.ai login)")
                    }
                    FieldRow("Appearance") {
                        PixelMenu(selection: store.appearance.title.uppercased()) {
                            ForEach(AppStore.Appearance.allCases, id: \.self) { item in
                                Button(item == .system ? "System — follows macOS" : item.title) { store.appearance = item }
                            }
                        }
                    }
                    FieldRow("Learn from how I use meepo") {
                        HStack(spacing: 6) {
                            Button(store.learnsUsage ? "ON" : "OFF") { store.learnsUsage.toggle() }
                            Button("FORGET") { store.forgetUsage() }
                                .help("Deletes every count so far")
                        }
                        .buttonStyle(PixelButtonStyle())
                        .help("Counts which panels and buttons you use, on this Mac only — no text, nothing sent. Automations then suggests hiding what you never touch.")
                    }
                    FieldRow("Server shells open") {
                        PixelMenu(selection: store.shellsBeside ? "BESIDE THE SESSION" : "IN A NEW TAB") {
                            Button("Beside the session — two terminals side by side") { store.shellsBeside = true }
                            Button("In a new tab") { store.shellsBeside = false }
                        }
                        .help("Where Servers → Open shell and + → Server Shell put ssh")
                    }
                    FieldRow("Screenshot to a session") {
                        PixelMenu(selection: store.screenshotHotKey.isEmpty ? "OFF" : store.screenshotHotKey) {
                            ForEach(GlobalHotKey.combos) { combo in Button(combo.title) { store.screenshotHotKey = combo.title } }
                            Button("Off") { store.screenshotHotKey = "" }
                        }
                        .help("Global hotkey: select an area, pick a session with ↑↓, Enter pastes the image into it")
                    }
                    StagesEditor()
                }
            }
        }
        .padding(16)
        .frame(width: 560, alignment: .leading)
        .frame(maxHeight: 560, alignment: .top)
        .background(Tokens.grass)
        .pixelFrame(6)
        .pixelConfirm(Binding(get: { store.confirmation }, set: { store.confirmation = $0 })) // CHECK NOW, the ⌘Q question
    }
}

/// Workflow order and the model/effort a new session gets in each stage; hidden ones can be added back.
struct StagesEditor: View {
    @Environment(AppStore.self) private var store
    private let efforts = ClaudeLauncher.effortLevels

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("STAGES").font(Fonts.title(16)).foregroundStyle(Tokens.text)
                Spacer()
                Button("Reset") { store.stages = Stage.defaults }.buttonStyle(PixelButtonStyle())
            }
            ForEach(Array(store.stages.enumerated()), id: \.element.id) { index, stage in
                HStack(spacing: 6) {
                    Text(stage.command.map { "/\($0)" } ?? "code").font(Fonts.mono(13)).foregroundStyle(Tokens.text)
                        .frame(width: 90, alignment: .leading)
                    let choices = store.modelChoices()
                    PixelMenu(selection: choices.first { $0.value == (stage.model ?? "") }?.title ?? stage.model ?? "Default") {
                        ForEach(choices, id: \.value) { option in
                            Button(option.title) { store.stages[index].model = option.value.isEmpty ? nil : option.value }
                        }
                    }
                    PixelMenu(selection: stage.effort ?? "effort") {
                        ForEach(efforts, id: \.self) { level in
                            Button(level.isEmpty ? "Default" : level) { store.stages[index].effort = level.isEmpty ? nil : level }
                        }
                    }
                    Spacer()
                    Button("▲") { store.stages.swapAt(index, index - 1) }.disabled(index == 0)
                    Button("▼") { store.stages.swapAt(index, index + 1) }.disabled(index == store.stages.count - 1)
                    Button("✕") { store.stages.remove(at: index) }
                }
                .buttonStyle(PixelButtonStyle())
            }
            let hidden = Stage.defaults.filter { stage in !store.stages.contains { $0.name == stage.name } }
            if !hidden.isEmpty {
                HStack(spacing: 6) {
                    Text("Hidden:").font(.caption).foregroundStyle(Tokens.textDim)
                    ForEach(hidden) { stage in
                        Button("+ \(stage.label)") { store.stages = Stage.adding(stage, to: store.stages) }
                            .buttonStyle(PixelButtonStyle(compact: true))
                    }
                }
            }
        }
        .padding(8)
        .background(Tokens.dirt)
        .sunken()
    }
}

/// The stages bar's own editor (right-click a stage → Edit stages…).
struct StagesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stages").font(Fonts.title(22))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(PixelButtonStyle(isPrimary: true))
            }
            Text("The buttons under the terminal, left to right. ✕ hides one; hidden ones can be added back below.")
                .foregroundStyle(Tokens.textDim)
            StagesEditor()
        }
        .padding(20)
        .frame(width: 600)
        .paperSheet()
    }
}
