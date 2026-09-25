import SwiftTerm
import SwiftUI

/// The window (Meepo 2.0, layout "c"): tabs on top — Home and every session — then the rail, panel zones
/// around the terminals, and a status bar. Where panels sit comes from `store.shell` (a preset or Custom).
struct MainView: View {
    @Environment(AppStore.self) private var store
    @State private var isPickingFolder = false
    @State private var isStatsShown = false
    @State private var isMorningShown = false
    @State private var isDayShown = false
    @State private var isToolsShown = false
    @State private var isNotesShown = false
    @State private var isImportShown = false
    @AppStorage("onboarded") private var isOnboarded = false

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(isStatsShown: $isStatsShown, isMorningShown: $isMorningShown, isDayShown: $isDayShown,
                     isToolsShown: $isToolsShown, isNotesShown: $isNotesShown, isImportShown: $isImportShown) { isPickingFolder = true }
            HStack(spacing: 0) {
                Rail()
                ZoneColumn(zone: .left)
                center
                ZoneColumn(zone: .right)
            }
            StatusBar()
        }
        .background(Tokens.ground)
        .ignoresSafeArea()
        .font(Fonts.ui(14))
        .foregroundStyle(Tokens.text)
        // Rail + one side zone + a usable terminal; the title bar fits unclipped from here up.
        .frame(minWidth: 1060, minHeight: 560)
        .preferredColorScheme(.light)
        // Explorer and Source Control share one git reading of the selected session's folder.
        .task(id: store.selectedSession.flatMap(store.workdir(of:))) {
            guard let path = store.selectedSession.flatMap(store.workdir(of:)) else { return }
            while !Task.isCancelled {
                await store.refreshSourceControl(path)
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .sheet(isPresented: Binding(
            get: { store.newSessionProjectId != nil },
            set: { if !$0 { store.newSessionProjectId = nil } }
        )) {
            NewSessionSheet()
        }
        .sheet(isPresented: $isStatsShown) { StatsView() }
        .sheet(isPresented: $isMorningShown) { TasksSheet() }
        .sheet(isPresented: $isDayShown) { DayView() }
        .sheet(isPresented: $isToolsShown) { ToolsView() }
        .sheet(isPresented: $isNotesShown) { NotesView() }
        .sheet(isPresented: $isImportShown) { ImportView() }
        .sheet(isPresented: Binding(get: { !isOnboarded }, set: { if !$0 { isOnboarded = true } })) { OnboardingView() }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            do {
                try store.addProject(at: result.get())
            } catch {
                store.confirmation = PixelConfirmation(title: "Couldn't add the project", message: error.localizedDescription,
                                                       action: "OK", cancel: nil, isDestructive: false) {}
            }
        }
        .pixelConfirm(Binding(get: { store.confirmation }, set: { store.confirmation = $0 }))
    }

    @ViewBuilder
    private var center: some View {
        VStack(spacing: 10) {
            if store.isHomeShown {
                HomeView()
            } else if store.selectedSession != nil {
                TerminalGrid(sessionIds: store.visibleSessionIds)
                if !store.shell.bottom.isEmpty {
                    ZoneRow(zone: .bottom).frame(height: 200)
                }
            } else {
                EmptyStateView()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // An empty bottom zone still takes a dropped panel.
        .overlay(alignment: .bottom) {
            if store.shell.bottom.isEmpty, !store.isHomeShown { DropStrip(zone: .bottom).frame(height: 14) }
        }
    }
}

/// Title bar: room for the traffic lights, Home and session tabs, +, the layout presets and the ≡ menu.
private struct TitleBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @Binding var isStatsShown: Bool
    @Binding var isMorningShown: Bool
    @Binding var isDayShown: Bool
    @Binding var isToolsShown: Bool
    @Binding var isNotesShown: Bool
    @Binding var isImportShown: Bool
    let onAddProject: () -> Void
    @State private var isFullScreen = false

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    TabButton(isOn: store.isHomeShown, action: { store.isHomeShown = true }) {
                        Image(systemName: "house").font(.system(size: 12, weight: .semibold))
                        Text("Home")
                    }
                    .help("All sessions at a glance")
                    ForEach(store.orderedSessions) { session in
                        SessionTab(session: session)
                    }
                    Menu {
                        Button("New Session…") { store.presentNewSession() }.disabled(store.projects.isEmpty)
                        Divider()
                        Button("Add Project Folder…", action: onAddProject)
                        Button("Add from Claude Code History…") { isImportShown = true }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.textDim)
                            .frame(width: 30, height: 30)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("New session or project (⌘N for a session)")
                }
            }
            UpdateBadge()
            PresetPicker()
            Menu {
                Button("Tasks — morning start") { isMorningShown = true }
                Button("Day — end-of-day summary") { isDayShown = true }
                Divider()
                Button("Stats") { isStatsShown = true }
                Button("Tools — practices, Docker, ports, changes") { isToolsShown = true }
                Button("Notes — release notes") { isNotesShown = true }
                Divider()
                Button("Settings…") { openSettings() }
            } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.textDim)
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.leading, isFullScreen ? 10 : 84) // room for the traffic lights, which full screen hides
        .padding(.trailing, 10)
        .frame(height: 50)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.line).frame(height: 1) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = false }
    }
}

/// A session's tab: state dot, project (and branch when the project has several sessions).
private struct SessionTab: View {
    @Environment(AppStore.self) private var store
    let session: Session

    var body: some View {
        let look = store.look(of: session)
        let project = store.project(for: session)?.name ?? "?"
        let siblings = store.sessions.filter { $0.projectId == session.projectId }.count
        TabButton(isOn: !store.isHomeShown && store.selectedSessionId == session.id,
                  action: { store.selectedSessionId = session.id }) {
            SelectionRing(kind: look.ring)
            Text(siblings > 1 ? "\(project) · \(session.worktreeName ?? session.branch ?? "")" : project)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200)
        }
        .contextMenu { SessionMenu(session: session) }
        .help("\(project) · \(look.text)")
    }
}

private struct TabButton<Label: View>: View {
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { label }
                .font(Fonts.ui(14, weight: isOn ? .bold : .medium))
                .foregroundStyle(isOn ? Tokens.text : Tokens.textDim)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(isOn ? Tokens.raised : .clear, in: RoundedRectangle(cornerRadius: 9))
                .shadow(color: isOn ? .black.opacity(0.10) : .clear, radius: 2, y: 1)
                .contentShape(Rectangle())
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// Focus / Deck / Full / Custom.
private struct PresetPicker: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ShellLayout.Preset.allCases) { preset in
                let isOn = store.shellPreset == preset
                Button(preset.title) { store.applyPreset(preset) }
                    .buttonStyle(.plain)
                    .font(Fonts.ui(13, weight: .semibold))
                    .foregroundStyle(isOn ? Tokens.text : Tokens.textDim)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(isOn ? Tokens.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .shadow(color: isOn ? .black.opacity(0.10) : .clear, radius: 2, y: 1)
                    .fixedSize()
                    .help(help(preset))
            }
        }
        .padding(3)
        .background(Tokens.ghost, in: RoundedRectangle(cornerRadius: 10))
    }

    private func help(_ preset: ShellLayout.Preset) -> String {
        switch preset {
        case .focus: "One terminal; what changed and who waits on the right"
        case .deck: "Four terminals at once, sessions on the left"
        case .full: "Explorer and Source Control on the left, two terminals, events and CI below"
        case .custom: "Your own arrangement — move any panel and it's saved here"
        }
    }
}

/// Left edge: one icon per panel (shows or hides it), how many terminals share the center, Settings.
private struct Rail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 4) {
            ForEach(ShellLayout.Panel.allCases) { panel in
                let isOn = store.shell.zone(of: panel) != nil
                RailButton(symbol: PanelBox.symbol(panel), isOn: isOn, help: isOn ? "Hide \(PanelBox.title(panel))" : "Show \(PanelBox.title(panel))") {
                    store.editShell { $0.toggle(panel) }
                }
            }
            Rectangle().fill(Tokens.line).frame(width: 24, height: 1).padding(.vertical, 6)
            ForEach(ShellLayout.splits, id: \.self) { split in
                RailButton(symbol: split == 1 ? "rectangle" : split == 2 ? "rectangle.split.2x1" : "square.grid.2x2",
                           isOn: store.shell.split == split, help: split == 1 ? "One terminal" : "\(split) terminals side by side") {
                    store.editShell { $0.split = split }
                }
            }
            Spacer()
            RailButton(symbol: "gearshape", isOn: false, help: "Settings (⌘,)") { openSettings() }
                .padding(.bottom, 8)
        }
        .padding(.top, 10)
        .frame(width: 52)
        .overlay(alignment: .trailing) { Rectangle().fill(Tokens.line).frame(width: 1) }
    }
}

private struct RailButton: View {
    let symbol: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isOn ? Tokens.text : Tokens.textDim)
                .frame(width: 38, height: 36)
                .background(isOn ? Tokens.raised : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A side zone: its panels stacked, sharing the height. Empty = a thin strip that takes a dropped panel.
private struct ZoneColumn: View {
    @Environment(AppStore.self) private var store
    let zone: ShellLayout.Zone

    var body: some View {
        let panels = store.shell[zone]
        if panels.isEmpty {
            DropStrip(zone: zone).frame(width: 12)
        } else {
            VStack(spacing: 10) {
                ForEach(panels) { PanelBox(panel: $0) }
            }
            .padding(10)
            .frame(width: zone == .left ? 272 : 320)
            .dropZone(zone)
            .overlay(alignment: zone == .left ? .trailing : .leading) { Rectangle().fill(Tokens.line).frame(width: 1) }
        }
    }
}

/// The bottom zone: panels side by side under the terminals.
private struct ZoneRow: View {
    @Environment(AppStore.self) private var store
    let zone: ShellLayout.Zone

    var body: some View {
        HStack(spacing: 10) {
            ForEach(store.shell[zone]) { PanelBox(panel: $0) }
        }
        .dropZone(zone)
    }
}

/// Where an empty zone is: invisible until a panel is dragged over it.
private struct DropStrip: View {
    let zone: ShellLayout.Zone
    @State private var isTargeted = false

    var body: some View {
        Rectangle().fill(isTargeted ? Tokens.workTint : .clear)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in drop(items) } isTargeted: { isTargeted = $0 }
    }

    @Environment(AppStore.self) private var store

    private func drop(_ items: [String]) -> Bool {
        guard let panel = items.first.flatMap(ShellLayout.Panel.init(rawValue:)) else { return false }
        store.editShell { $0.move(panel, to: zone) }
        return true
    }
}

private struct DropZoneModifier: ViewModifier {
    @Environment(AppStore.self) private var store
    let zone: ShellLayout.Zone
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background(isTargeted ? Tokens.workTint : .clear)
            .dropDestination(for: String.self) { items, _ in
                guard let panel = items.first.flatMap(ShellLayout.Panel.init(rawValue:)) else { return false }
                store.editShell { $0.move(panel, to: zone) }
                return true
            } isTargeted: { isTargeted = $0 }
    }
}

private extension View {
    func dropZone(_ zone: ShellLayout.Zone) -> some View { modifier(DropZoneModifier(zone: zone)) }
}

/// One panel: a header you drag to another zone (or move from its menu), and its content, scrolling.
private struct PanelBox: View {
    @Environment(AppStore.self) private var store
    let panel: ShellLayout.Panel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: Self.symbol(panel)).font(.system(size: 11, weight: .semibold))
                Text(Self.title(panel).uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1.2)
                Spacer(minLength: 0)
                Menu {
                    ForEach(ShellLayout.Zone.allCases, id: \.self) { zone in
                        Button("Move to \(zone.rawValue.capitalized)") { store.editShell { $0.move(panel, to: zone) } }
                            .disabled(store.shell.zone(of: panel) == zone)
                    }
                    Divider()
                    Button("Hide") { store.editShell { $0.remove(panel) } }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 18)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("\(Self.title(panel)) panel options")
            }
            .foregroundStyle(Tokens.textDim)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
            .draggable(panel.rawValue)
            .help("Drag to another side of the window")
            Rectangle().fill(Tokens.line).frame(height: 1)
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokens.line))
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .sessions: SessionsPanel()
        case .explorer:
            if let path = store.selectedSession.flatMap(store.workdir(of:)) {
                ExplorerSection(root: path, changes: store.sourceControl?.changes ?? [])
            } else {
                Text("Select a session to browse its folder.").font(.caption).foregroundStyle(Tokens.textDim)
            }
        case .changes: SourceControlPanel()
        case .ci: CIPanel()
        case .events: EventsPanel()
        case .waiting: WaitingPanel()
        }
    }

    static func title(_ panel: ShellLayout.Panel) -> String {
        switch panel {
        case .sessions: "Sessions"
        case .explorer: "Explorer"
        case .changes: "Source Control"
        case .ci: "CI"
        case .events: "Events"
        case .waiting: "Needs you"
        }
    }

    static func symbol(_ panel: ShellLayout.Panel) -> String {
        switch panel {
        case .sessions: "list.bullet"
        case .explorer: "folder"
        case .changes: "arrow.triangle.branch"
        case .ci: "checkmark.seal"
        case .events: "bolt"
        case .waiting: "bell"
        }
    }
}

/// Sessions that wait for an answer; a click opens one (Ctrl+Tab does the same from anywhere).
private struct WaitingPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let waiting = store.orderedSessions.filter { store.look(of: $0).ring == .waiting }
        VStack(alignment: .leading, spacing: 2) {
            if waiting.isEmpty {
                Text("Nobody is waiting.").font(.caption).foregroundStyle(Tokens.textDim)
            }
            ForEach(waiting) { session in
                Button { store.selectedSessionId = session.id } label: {
                    HStack(spacing: 10) {
                        SelectionRing(kind: .waiting)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.project(for: session)?.name ?? "?").font(Fonts.ui(14, weight: .semibold))
                            Text(store.look(of: session).text).font(.caption).foregroundStyle(Tokens.need)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The center's terminals: the selected session plus the next ones, 1, 2 or 4 (2×2) at a time.
private struct TerminalGrid: View {
    @Environment(AppStore.self) private var store
    let sessionIds: [Int64]

    /// A terminal narrower than this is unusable; a narrow window shows fewer instead of squeezing them.
    private static let minPaneWidth: CGFloat = 400

    var body: some View {
        GeometryReader { geometry in
            // Room for two across means room for the 2×2 grid too; otherwise one terminal.
            let capacity = geometry.size.width + 10 >= 2 * (Self.minPaneWidth + 10) ? 4 : 1
            grid(Array(sessionIds.prefix(capacity)))
                .onChange(of: capacity, initial: true) { _, capacity in store.fittingPanes = capacity }
        }
    }

    @ViewBuilder
    private func grid(_ ids: [Int64]) -> some View {
        let focused = store.selectedSessionId
        let panes = ids.map { TerminalPane(sessionId: $0, isFocused: $0 == focused, isSplit: ids.count > 1) }
        if panes.count <= 2 {
            HStack(spacing: 10) { ForEach(panes.indices, id: \.self) { panes[$0] } }
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 10) { ForEach(0..<2, id: \.self) { panes[$0] } }
                HStack(spacing: 10) { ForEach(2..<panes.count, id: \.self) { panes[$0] } }
            }
        }
    }
}

/// One session: header (state, project, branch, model), its live terminal, and the stage bar.
private struct TerminalPane: View {
    @Environment(AppStore.self) private var store
    let sessionId: Int64
    let isFocused: Bool
    let isSplit: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let session = store.sessions.first(where: { $0.id == sessionId }) {
                header(session)
                Rectangle().fill(Tokens.line).frame(height: 1)
                terminal
                Rectangle().fill(Tokens.line).frame(height: 1)
                StagePanel(session: session)
            }
        }
        .background(Tokens.terminalBg, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isFocused && isSplit ? Tokens.work : Tokens.line,
                                                                 lineWidth: isFocused && isSplit ? 1.5 : 1))
        // Launch lazily when a session is first shown (also after Meepo restarts).
        .task(id: sessionId) { store.startTerminalIfNeeded(sessionId) }
    }

    private func header(_ session: Session) -> some View {
        let look = store.look(of: session)
        return HStack(spacing: 8) {
            SelectionRing(kind: look.ring)
            Text(store.project(for: session)?.name ?? "").font(Fonts.ui(14, weight: .bold))
                .lineLimit(1).truncationMode(.middle).layoutPriority(2)
            Text(session.worktreeName.map { "worktree \($0)" } ?? session.branch ?? "").font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
                .lineLimit(1).layoutPriority(1)
            Text(look.text).font(.caption).foregroundStyle(look.ring == .waiting ? Tokens.need : Tokens.textDim)
                .lineLimit(1).fixedSize().layoutPriority(3)
            Spacer(minLength: 4)
            if !isSplit { // the status bar shows the selected session's model anyway
                Text([session.model, session.effort].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Tokens.textDim).lineLimit(1)
            }
            Menu { SessionMenu(session: session) } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.textDim)
                    .frame(width: 24, height: 20)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Session options")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedSessionId = sessionId }
    }

    private var terminal: some View {
        ZStack(alignment: .bottom) {
            Tokens.terminalBg
            if let view = store.terminalView(for: sessionId),
               store.runningSessionIds.contains(sessionId) || store.exitedSessionIds.contains(sessionId) {
                TerminalHost(terminal: view, isFocused: isFocused) { store.selectedSessionId = sessionId }
                    .padding(8)
            }
            if store.terminalView(for: sessionId) == nil {
                LaunchState()
            }
            if store.exitedSessionIds.contains(sessionId) {
                HStack {
                    Text("Session exited")
                    Button("Continue") { store.restartSession(sessionId) }
                        .buttonStyle(PixelButtonStyle(isPrimary: true))
                        .keyboardShortcut(.defaultAction)
                }
                .pixelFrame(10)
                .padding()
            }
        }
    }
}

/// No session yet: what to do next.
private struct EmptyStateView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Text(store.projects.isEmpty ? "Add a project to start" : "No session open")
                .font(Fonts.ui(28, weight: .bold))
            Text(store.projects.isEmpty ? "Use + above: a folder, or one Claude Code already knows." : "Start Claude Code in one of your projects.")
                .foregroundStyle(Tokens.textDim)
            if !store.projects.isEmpty {
                Button("Start Session") { store.presentNewSession() }
                    .buttonStyle(PixelButtonStyle(large: true, isPrimary: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bottom line: who waits, tokens, the selected session's model, bridge problems, preset, version.
private struct StatusBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 18) {
            if store.waitingCount > 0 {
                Button { store.selectNextWaiting() } label: {
                    HStack(spacing: 6) {
                        SelectionRing(kind: .waiting, size: 7)
                        Text("\(store.waitingCount) need\(store.waitingCount == 1 ? "s" : "") you").fontWeight(.bold)
                    }
                    .foregroundStyle(Tokens.need)
                }
                .buttonStyle(.plain)
                .help("Open the next one — Ctrl+Tab")
            } else {
                Text("Nobody waiting")
            }
            Text("\(TokenFormat.short(store.sessionUsage.values.reduce(0) { $0 + $1.tokensToday })) tokens today")
            if let session = store.selectedSession, !store.isHomeShown {
                Text([session.model ?? "default model", session.effort].compactMap { $0 }.joined(separator: " · "))
            }
            BridgeIssues()
            Spacer(minLength: 8)
            Text(store.shellPreset.title)
            if let version = Updater.currentVersion { Text("Meepo \(version.description)") }
        }
        .font(Fonts.ui(12))
        .foregroundStyle(Tokens.textDim)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Tokens.statusBar)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.line).frame(height: 1) }
    }
}

/// Hosts a cached terminal view; swapping views keeps every session's process alive.
/// A click inside selects the session, since the terminal itself swallows the mouse.
private struct TerminalHost: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    let isFocused: Bool
    let onClick: () -> Void

    final class Container: NSView {
        var onClick: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.onClick?()
                return event
            }
        }
    }

    final class Coordinator { var wasFocused = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        container.onClick = onClick
        let attached = container.subviews.first === terminal
        if !attached {
            container.subviews.forEach { $0.removeFromSuperview() }
            terminal.frame = container.bounds
            terminal.autoresizingMask = [.width, .height]
            container.addSubview(terminal)
            terminal.needsLayout = true
            terminal.needsDisplay = true
        }
        // Only the selected pane takes the keyboard; the others just show their session.
        if isFocused, !attached || !context.coordinator.wasFocused {
            DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        }
        context.coordinator.wasFocused = isFocused
    }
}

/// Makes an empty area behave like a title bar: drag moves the window, double-click zooms.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Instead of an empty terminal: claude is starting, or it can't be found — with what to do about it.
private struct LaunchState: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            if !store.isLoginResolved {
                Text("Starting claude…").foregroundStyle(Tokens.textDim)
            } else if store.loginEnvironment == nil {
                Text("CLAUDE NOT FOUND").font(Fonts.title(16)).foregroundStyle(Tokens.warn)
                Text("Meepo asks your login shell ($SHELL -l -i) for `claude` and got nothing: it isn't installed, it's only an alias, or ~/.zshrc took over 15 s.")
                    .font(.caption).foregroundStyle(Tokens.text).multilineTextAlignment(.center)
                Text("curl -fsSL https://claude.ai/install.sh | bash")
                    .font(Fonts.mono(12)).foregroundStyle(Tokens.screen).textSelection(.enabled)
                Button("RETRY") { Task { await store.resolveLogin() } }
                    .buttonStyle(PixelButtonStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: 520, maxHeight: .infinity)
    }
}

/// Title-bar update state: downloading, ready (installs at quit, or RESTART now), or update by hand.
private struct UpdateBadge: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        switch store.updateState {
        case let .downloading(version):
            Text("↓ \(version)").font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
                .help("Downloading Meepo \(version)")
        case let .ready(version, notes):
            Button("\(version) READY") {
                store.confirmation = PixelConfirmation(
                    title: "RESTART INTO \(version.uppercased())?",
                    message: (notes.isEmpty ? "" : String(notes.prefix(400)) + "\n\n")
                        + "Sessions come back where they were (claude --resume). Or keep working: it installs when you quit Meepo.",
                    action: "RESTART",
                    isDestructive: false
                ) {
                    if store.installStagedUpdate() {
                        Updater.relaunch(Bundle.main.bundleURL)
                        NSApp.terminate(nil)
                    }
                }
            }
            .foregroundStyle(Tokens.selection)
            .help("Meepo \(version) is downloaded and checked; it installs when you quit, or restart now")
        case let .manual(version, page):
            if let url = URL(string: page) {
                Link("UPDATE \(version)", destination: url)
                    .font(Fonts.title(16))
                    .foregroundStyle(Tokens.selection)
                    .help("This copy can't update itself here: brew upgrade --cask meepo, or download it")
            }
        default:
            EmptyView()
        }
    }
}
