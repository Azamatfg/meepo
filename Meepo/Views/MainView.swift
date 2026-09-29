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
    @State private var isNotesShown = false
    @State private var isImportShown = false
    @AppStorage("onboarded") private var isOnboarded = false
    @State private var isFirstRunShown = false

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(isStatsShown: $isStatsShown, isMorningShown: $isMorningShown, isDayShown: $isDayShown,
                     isNotesShown: $isNotesShown, isImportShown: $isImportShown) { isPickingFolder = true }
            HStack(spacing: 0) {
                Rail().zIndex(1) // its hover labels lie over the panels next to it
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
        // Explorer and Source Control share one git reading of the selected session's folder.
        .task(id: store.selectedSessionId) {
            while !Task.isCancelled {
                if let session = store.selectedSession { await store.refreshSourceControls(for: session) }
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
        .sheet(isPresented: Binding(get: { store.toolsTab != nil }, set: { if !$0 { store.toolsTab = nil } })) {
            ToolsView(tab: store.toolsTab ?? .docker)
        }
        .sheet(isPresented: $isNotesShown) { NotesView() }
        .sheet(isPresented: $isImportShown) { ImportView() }
        .sheet(isPresented: Binding(get: { store.isSettingsShown }, set: { store.isSettingsShown = $0 })) { SettingsView() }
        .sheet(item: Binding(get: { store.outputAgent }, set: { store.outputAgent = $0 })) { AgentOutputSheet(agent: $0) }
        // Today's click on a push: What changed shows it even when the panel isn't in the layout.
        .sheet(isPresented: Binding(get: { store.isWhatChangedShown }, set: { store.isWhatChangedShown = $0 })) { WhatChangedSheet() }
        .sheet(isPresented: Binding(get: { store.renamingSessionId != nil }, set: { if !$0 { store.renamingSessionId = nil } })) {
            if let id = store.renamingSessionId, let session = store.sessions.first(where: { $0.id == id }) {
                RenameSheet(session: session)
            }
        }
        .sheet(isPresented: $isFirstRunShown) { OnboardingView(isFirstRun: true) }
        // Marked as seen once shown, not when closed: quitting with it open must not bring it back every launch.
        .onAppear { if !isOnboarded { isOnboarded = true; isFirstRunShown = true } }
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

/// Title bar: room for the traffic lights, the ≡ menu, Home and session tabs, +, and the layout presets.
private struct TitleBar: View {
    @Environment(AppStore.self) private var store
    @Binding var isStatsShown: Bool
    @Binding var isMorningShown: Bool
    @Binding var isDayShown: Bool
    @Binding var isNotesShown: Bool
    @Binding var isImportShown: Bool
    let onAddProject: () -> Void
    @State private var isFullScreen = false
    @State private var isSetupShown = false
    @State private var isAutomationsShown = false
    @State private var isWelcomeShown = false
    @State private var isGuideShown = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Tasks — morning start") { isMorningShown = true }
                Button("Day — end-of-day summary") { isDayShown = true }
                Divider()
                Button("Stats") { isStatsShown = true }
                Button("Tools — Docker space, ports, servers, meepo's edits") { store.toolsTab = .docker }
                Button("Notes — release notes") { isNotesShown = true }
                Divider()
                Toggle("Guided mode — Claude explains, asks first", isOn: Binding(get: { store.guidedMode }, set: { store.setGuidedMode($0) }))
                Button("How meepo works…") { isGuideShown = true }
                Button("Welcome…") { isWelcomeShown = true }
                Divider()
                Button("Automations…") { isAutomationsShown = true }
                Button("Claude Code Setup…") { isSetupShown = true }
                Button("Send Feedback…") { NSWorkspace.shared.open(CrashNotice.newIssue(title: "", body: "")) }
                Button("Settings…") { store.isSettingsShown = true }
            } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.textDim)
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Menu — Tasks, Day, Stats, Tools, Automations, Settings")
            .accessibilityLabel("Menu")
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
                        Menu("Server Shell") {
                            ForEach(store.servers) { server in
                                Button("\(store.projects.first { $0.id == server.projectId }?.name ?? "?") · \(server.title)") {
                                    do { try store.openShell(on: server) } catch { store.bridgeError = error.localizedDescription }
                                }
                            }
                            if !store.servers.isEmpty { Divider() }
                            Button("Add a server…") { store.presentAddServer(projectId: nil) }
                        }
                        Divider()
                        Button("Add Project Folder…", action: onAddProject)
                        Button("Add from Claude Code History…") { isImportShown = true }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.textDim)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle()) // plain style: otherwise only the + itself takes the click
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
            InfoButton(title: "Layouts", text: Explain.presets)
        }
        .padding(.leading, isFullScreen ? 10 : 84) // room for the traffic lights, which full screen hides
        .padding(.trailing, 10)
        .frame(height: 50)
        .background(WindowDragArea())
        .sheet(isPresented: $isSetupShown) { SetupView() }
        .sheet(isPresented: $isAutomationsShown) { AutomationsView() }
        .sheet(isPresented: $isWelcomeShown) { OnboardingView() }
        .sheet(isPresented: $isGuideShown) { GuideSheet() }
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.line).frame(height: 1) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = false }
    }
}

/// A session's tab: state dot, project (and branch when the project has several sessions).
private struct SessionTab: View {
    @Environment(AppStore.self) private var store
    let session: Session
    @State private var isHovered = false
    @State private var isDropTarget = false

    var body: some View {
        let look = store.look(of: session)
        let project = store.project(for: session)?.name ?? "?"
        TabButton(isOn: !store.isHomeShown && store.selectedSessionId == session.id,
                  action: { store.selectedSessionId = session.id }) {
            SelectionRing(kind: look.ring)
            Text(store.tabLabel(of: session))
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200)
            Color.clear.frame(width: 14, height: 14) // room for the ×, laid over the tab below
        }
        .overlay(alignment: .trailing) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.textDim)
            .padding(.trailing, 9)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .help("Close this session")
        }
        .onHover { isHovered = $0 }
        // Drag a tab onto another to put it there; the order stays after meepo restarts.
        .draggable(AppStore.tabDragPrefix + String(session.id ?? -1))
        .dropDestination(for: String.self) { items, _ in
            guard let id = AppStore.draggedTab(items), let target = session.id else { return false }
            store.moveTab(id, onto: target)
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay(alignment: .leading) { if isDropTarget { Capsule().fill(Tokens.work).frame(width: 3).padding(.vertical, 6) } }
        .contextMenu { SessionMenu(session: session) }
        .help("\(project) · \(look.text)")
    }

    /// Closes right away when claude is between turns; asks first while it works or waits on you mid-turn.
    private func close() {
        // Not running (no ring): no turn to cut off either.
        guard session.sshHost == nil, let ring = store.look(of: session).ring, ring != .idle else { return store.closeSession(session.id!) }
        store.confirmation = PixelConfirmation(
            title: "Close this session in the middle of a turn?",
            message: "claude stops mid-turn. Files and commits stay; the conversation stays in Claude Code (claude --resume).",
            action: "Close"
        ) { store.closeSession(session.id!) }
    }
}

extension AppStore {
    /// A session tab's caption: the project, plus the session's name when the project has several.
    func tabLabel(of session: Session) -> String {
        let name = project(for: session)?.name ?? "?"
        if session.sshHost != nil { return "\(name) · ssh \(displayName(of: session))" } // told apart from claude at a glance
        return sessions.filter { $0.projectId == session.projectId && $0.sshHost == nil }.count > 1 ? "\(name) · \(displayName(of: session))" : name
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
                let isEdited = store.editedLayouts[preset] != nil
                Button(preset.title + (isEdited ? "•" : "")) { store.applyPreset(preset) }
                    .buttonStyle(.plain)
                    .font(Fonts.ui(13, weight: .semibold))
                    .foregroundStyle(isOn ? Tokens.text : Tokens.textDim)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(isOn ? Tokens.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .shadow(color: isOn ? .black.opacity(0.10) : .clear, radius: 2, y: 1)
                    .fixedSize()
                    .help(help(preset) + (isEdited ? ". • = you changed it; right-click to reset" : ""))
                    .contextMenu {
                        Button("Reset \(preset.title) to default") { store.resetPreset(preset) }.disabled(!isEdited)
                    }
            }
        }
        .padding(3)
        .background(Tokens.ghost, in: RoundedRectangle(cornerRadius: 10))
    }

    private func help(_ preset: ShellLayout.Preset) -> String {
        switch preset {
        case .focus: "One terminal; what changed for users and who waits on the right"
        case .deck: "Four terminals at once, sessions on the left"
        case .full: "Explorer and Source Control on the left, two terminals, events and CI below"
        }
    }
}

/// Left edge: one icon per panel (shows or hides it), how many terminals share the center, Settings.
private struct Rail: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 4) {
            ForEach(ShellLayout.Panel.allCases) { panel in
                let isOn = store.shell.zone(of: panel) != nil
                RailButton(symbol: PanelBox.symbol(panel), isOn: isOn, name: PanelBox.title(panel),
                           hint: PanelBox.hint(panel), click: isOn ? "Click to hide" : "Click to show") {
                    store.editShell { $0.toggle(panel) }
                }
            }
            Rectangle().fill(Tokens.line).frame(width: 24, height: 1).padding(.vertical, 6)
            ForEach(ShellLayout.splits, id: \.self) { split in
                RailButton(symbol: split == 1 ? "rectangle" : split == 2 ? "rectangle.split.2x1" : "square.grid.2x2",
                           isOn: store.shell.split == split,
                           name: split == 1 ? "1 terminal" : split == 2 ? "2 terminals" : "4 terminals",
                           hint: split == 1 ? "One session at a time" : split == 2 ? "Two sessions side by side" : "Four sessions, 2 × 2",
                           click: store.shell.split == split ? "Shown now" : "Click to switch") {
                    store.editShell { $0.split = split }
                }
            }
            Spacer()
            RailButton(symbol: "gearshape", isOn: false, name: "Settings", hint: "meepo's settings", click: "⌘,") { store.isSettingsShown = true }
                .padding(.bottom, 8)
        }
        .padding(.top, 10)
        .frame(width: 52)
        .overlay(alignment: .trailing) { Rectangle().fill(Tokens.line).frame(width: 1) }
    }
}

/// An icon that names itself the moment the pointer is on it — a system tooltip waits too long to explain
/// an unfamiliar icon (feedback from the tester, 2026-09-25).
private struct RailButton: View {
    let symbol: String
    let isOn: Bool
    let name: String
    let hint: String
    let click: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isOn ? Tokens.text : Tokens.textDim)
                .frame(width: 38, height: 36)
                .background(isOn ? Tokens.raised : isHovered ? Tokens.ghost : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .overlay(alignment: .leading) {
            if isHovered {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Fonts.ui(13, weight: .bold))
                    Text(hint).font(.caption).foregroundStyle(Tokens.textDim)
                    Text(click).font(.caption2).foregroundStyle(Tokens.work)
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Tokens.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Tokens.line))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .offset(x: 48)
                .allowsHitTesting(false)
            }
        }
        .zIndex(isHovered ? 1 : 0)
        .accessibilityLabel("\(name): \(hint)")
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
                // Whose files, commits, CI: the selected session's project. Where it doesn't fit, the name loses its
                // middle, then the title its end — never down to a bare "…".
                if Self.perProject.contains(panel), let session = store.selectedSession {
                    // Not ViewThatFits: on macOS 15 it measures its options off the main thread, and InfoButton's
                    // action is a main-actor closure — the tester's crash (2026-09-25). The name gives way instead.
                    titled(project: store.project(for: session)?.name ?? "", tab: store.tabLabel(of: session))
                } else {
                    titled()
                }
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
                        .contentShape(Rectangle()) // plain style: otherwise only the three dots take the click
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
                // minWidth 0: exactly the panel's width, so a long row (an author's name, a path) can't widen it.
                // (containerRelativeFrame measured the window here, not the scroll view.)
                content.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Tokens.line))
    }

    private func titled(project: String? = nil, tab: String = "") -> some View {
        HStack(spacing: 7) {
            Text(Self.title(panel).uppercased()).font(Fonts.ui(11, weight: .bold)).tracking(1.2).lineLimit(1)
                .layoutPriority(1)
            InfoButton(title: Self.title(panel), text: Explain.panel(panel))
            if let project {
                // The project comes first (the icon already says which panel); a long name still ends in the middle.
                Text(project.count > 18 ? "\(project.prefix(9))…\(project.suffix(8))" : project)
                    .font(Fonts.ui(11, weight: .semibold)).foregroundStyle(Tokens.text)
                    .fixedSize()
                    .layoutPriority(2)
                    .help("For the selected tab: \(tab)")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .sessions: SessionsPanel()
        case .explorer:
            if let path = store.selectedSession.flatMap(store.workdir(of:)) {
                ExplorerSection(root: path, changes: store.changes(under: path))
            } else {
                Text("Select a session to browse its folder.").font(.caption).foregroundStyle(Tokens.textDim)
            }
        case .changes: SourceControlPanel()
        case .ci: CIPanel()
        case .events: EventsPanel()
        case .waiting: WaitingPanel()
        case .product: WhatChangedPanel()
        }
    }

    private static let perProject: Set<ShellLayout.Panel> = [.explorer, .changes, .ci, .events, .product]

    static func title(_ panel: ShellLayout.Panel) -> String {
        switch panel {
        case .sessions: "Sessions"
        case .explorer: "Explorer"
        case .changes: "Source Control"
        case .ci: "CI"
        case .events: "Events"
        case .waiting: "Needs you"
        case .product: "What changed"
        }
    }

    /// What the panel is for, in a few plain words — for the rail's hover label.
    static func hint(_ panel: ShellLayout.Panel) -> String {
        switch panel {
        case .sessions: "All your Claude sessions, by project"
        case .explorer: "The project's files"
        case .changes: "Git: changes, teammates' commits, push"
        case .ci: "Builds, tests and deploys"
        case .events: "What the agent did, step by step"
        case .waiting: "Sessions waiting for your answer"
        case .product: "What changed, for your users"
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
        case .product: "sparkles"
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
                            Text("\(store.project(for: session)?.name ?? "?") · \(store.displayName(of: session))")
                                .font(Fonts.ui(14, weight: .semibold)).lineLimit(1)
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
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            if let session = store.sessions.first(where: { $0.id == sessionId }) {
                header(session)
                Rectangle().fill(Tokens.line).frame(height: 1)
                terminal(host: session.sshHost)
                if session.sshHost == nil { // stages, slash commands and voice are claude's
                    Rectangle().fill(Tokens.line).frame(height: 1)
                    StagePanel(session: session)
                }
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
            Text(store.displayName(of: session)).font(Fonts.ui(14)).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                .onTapGesture(count: 2) { store.renamingSessionId = sessionId }
                .help("Double-click to rename")
            Text(session.worktreeName.map { "worktree \($0)" } ?? session.branch ?? "").font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
                .lineLimit(1)
            Text(look.text).font(.caption).foregroundStyle(look.ring == .waiting ? Tokens.need : Tokens.textDim)
                .lineLimit(1).fixedSize().layoutPriority(3)
            if store.interruptedSessionIds.contains(sessionId) {
                Button("Continue") { store.continueInterrupted(sessionId) }
                    .buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
                    .help("meepo closed while this session was working; its last turn stopped halfway. Asks claude to pick it up")
            }
            Spacer(minLength: 4)
            if !isSplit { // the status bar shows the selected session's model anyway
                Text(store.modelLine(of: session)).font(.caption).foregroundStyle(Tokens.textDim).lineLimit(1)
            }
            Menu { SessionMenu(session: session) } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.textDim)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle()) // plain style: otherwise only the three dots take the click
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
        // Drag a pane by its header onto another: the two trade places (and so do their tabs).
        .draggable(AppStore.tabDragPrefix + String(sessionId))
        .dropDestination(for: String.self) { items, _ in
            guard let id = AppStore.draggedTab(items) else { return false }
            store.swapTabs(id, sessionId)
            return true
        } isTargeted: { isDropTarget = $0 }
        .background(isDropTarget ? Tokens.workTint : .clear)
        .help(isSplit ? "Drag by this bar onto another terminal to swap them" : "")
    }

    private func terminal(host: String?) -> some View {
        ZStack(alignment: .bottom) {
            Tokens.terminalBg
            if let view = store.terminalView(for: sessionId),
               store.runningSessionIds.contains(sessionId) || store.exitedSessionIds.contains(sessionId) {
                TerminalHost(terminal: view, isFocused: isFocused) {
                    store.selectedSessionId = sessionId
                } onDrop: { urls in
                    store.selectedSessionId = sessionId
                    store.dropFiles(urls, into: sessionId)
                }
                    .padding(8)
            }
            if store.terminalView(for: sessionId) == nil {
                if let host {
                    HStack {
                        Text("Shell on \(host)")
                        Button("Connect") { store.connectShell(sessionId) }
                            .buttonStyle(PixelButtonStyle(isPrimary: true))
                            .keyboardShortcut(.defaultAction)
                    }
                    .pixelFrame(10)
                    .frame(maxHeight: .infinity)
                } else {
                    LaunchState()
                }
            }
            if store.exitedSessionIds.contains(sessionId) {
                HStack {
                    Text(host == nil ? "Session exited" : "Disconnected")
                    Button(host == nil ? "Continue" : "Reconnect") { store.restartSession(sessionId) }
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
            if let limits = store.usageLimits {
                if let five = limits.fiveHour { LimitLabel(name: "5h", limit: five) }
                if let seven = limits.sevenDay { LimitLabel(name: "7d", limit: seven) }
            }
            if let session = store.selectedSession, !store.isHomeShown {
                Text(store.modelLine(of: session))
            }
            BridgeIssues()
            if store.quitWhenIdle {
                HStack(spacing: 6) {
                    Text(store.relaunchAfterQuit ? "Restarts when agents finish" : "Quits when agents finish").foregroundStyle(Tokens.warn)
                    Button("Cancel") { store.cancelQuitWhenIdle() }.buttonStyle(.plain).foregroundStyle(Tokens.work)
                }
            }
            if let report = store.lastCrashReport { CrashNotice(report: report) }
            Spacer(minLength: 8)
            if case let .ready(version, _) = store.updateState {
                Button("meepo \(version) ready · Restart") {
                    store.relaunchAfterQuit = true
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain).foregroundStyle(Tokens.work).fontWeight(.semibold)
                .help("Downloaded and checked. Restart now, or it installs when you quit meepo")
            }
            if let claude = store.claudeVersion { Text("Claude Code \(claude)") }
            Text(store.shellPreset.title)
            if let version = Updater.currentVersion { Text("meepo \(version.description)") }
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

/// "5h 42% · 14:00": how much of the plan's limit is used, and when it resets. Amber from 80%.
private struct LimitLabel: View {
    let name: String
    let limit: StatusLine.Limit

    var body: some View {
        let reset = limit.resetsAt.map { " · " + $0.formatted(date: Calendar.current.isDateInToday($0) ? .omitted : .abbreviated, time: .shortened) } ?? ""
        Text("\(name) \(Int(limit.percent.rounded()))%\(reset)")
            .foregroundStyle(limit.percent >= 80 ? Tokens.warn : Tokens.textDim)
            .help("Plan usage over \(name == "5h" ? "5 hours" : "7 days"), as Claude Code reports it\(limit.resetsAt.map { "; resets \($0.formatted())" } ?? "")")
    }
}

/// "meepo quit unexpectedly last time": the report stays on this Mac until the user copies or opens it.
private struct CrashNotice: View {
    @Environment(AppStore.self) private var store
    let report: URL
    @State private var isCopied = false

    var body: some View {
        HStack(spacing: 8) {
            Text("meepo quit unexpectedly last time").foregroundStyle(Tokens.need)
            Button(isCopied ? "Copied" : "Copy report") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(CrashReports.text(of: report), forType: .string)
                isCopied = true
            }
            .buttonStyle(.plain).foregroundStyle(Tokens.work)
            Button("Report on GitHub") {
                NSWorkspace.shared.open(Self.newIssue(title: "Crash in meepo \(Updater.currentVersion?.description ?? "")",
                                                      body: "What were you doing?\n\n(Copy report in meepo, then paste it here.)"))
            }
            .buttonStyle(.plain).foregroundStyle(Tokens.work)
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([report]) }
                .buttonStyle(.plain).foregroundStyle(Tokens.work)
            Button("✕") { store.dismissCrashReport() }.buttonStyle(.plain).foregroundStyle(Tokens.textDim)
                .accessibilityLabel("Dismiss")
        }
        .help(report.path)
    }

    static func newIssue(title: String, body: String) -> URL {
        var components = URLComponents(string: "https://github.com/Azamatfg/meepo/issues/new")!
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        return components.url!
    }
}

/// Hosts a cached terminal view; swapping views keeps every session's process alive.
/// A click inside selects the session, since the terminal itself swallows the mouse. Files dropped on it go to
/// the session (SwiftTerm doesn't take drops; AppKit hands them to this container, the nearest view that does).
private struct TerminalHost: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    let isFocused: Bool
    let onClick: () -> Void
    let onDrop: ([URL]) -> Void

    final class Container: NSView {
        var onClick: (() -> Void)?
        var onDrop: (([URL]) -> Void)?
        private var monitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL])
        }

        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            Drops.fileURLs(sender.draggingPasteboard).isEmpty ? [] : .copy
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = Drops.fileURLs(sender.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            onDrop?(urls)
            return true
        }

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
        container.onDrop = onDrop
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
                Text("meepo asks your login shell ($SHELL -l -i) for `claude` and got nothing: it isn't installed, it's only an alias, or ~/.zshrc took over 15 s.")
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
                .help("Downloading meepo \(version)")
        case let .ready(version, notes):
            Button("\(version) READY") {
                store.confirmation = PixelConfirmation(
                    title: "RESTART INTO \(version.uppercased())?",
                    message: (notes.isEmpty ? "" : String(notes.prefix(400)) + "\n\n")
                        + "Sessions come back where they were (claude --resume); if an agent is mid-turn, meepo asks first. Or keep working: it installs when you quit meepo.",
                    action: "RESTART",
                    isDestructive: false
                ) {
                    store.relaunchAfterQuit = true
                    NSApp.terminate(nil)
                }
            }
            .foregroundStyle(Tokens.selection)
            .help("meepo \(version) is downloaded and checked; it installs when you quit, or restart now")
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
