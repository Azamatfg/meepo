import GRDB
import SwiftUI

@main
struct MeepoApp: App {
    @State private var store: AppStore
    @NSApplicationDelegateAdaptor(QuitHandler.self) private var quitHandler
    private let hotkeys: HotkeyMonitor
    private let services: LiveServices?
    /// Unit tests host the app: keep them off the real database and away from real sessions.
    private let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        // A child that exits before reading its stdin (claude -p) must fail the write, not kill meepo.
        signal(SIGPIPE, SIG_IGN)
        Fonts.register()
        do {
            // Demo mode: made-up projects, nothing of the user's read or written (see Demo).
            let isolated = isTesting || Demo.isOn
            let db = isolated ? try DatabaseQueue() : try AppDatabase.openShared()
            if isolated { try AppDatabase.migrator.migrate(db) }
            var defaults = UserDefaults.standard
            // Settings of their own, fresh each launch: AppStore.init upgrades old keys (0.3's buttons, …), and a
            // test run must not do that to the user's.
            let suite = Demo.isOn ? "com.azamatfg.meepo.demo" : "com.azamatfg.meepo.tests"
            if isolated, let own = UserDefaults(suiteName: suite) {
                own.removePersistentDomain(forName: suite)
                defaults = own
            }
            let store = AppStore(db: db, bridge: Demo.isOn ? Self.demoBridge() : BridgeInstaller(), defaults: defaults)
            _store = State(initialValue: store)
            hotkeys = HotkeyMonitor(store: store)
            services = isolated ? nil : LiveServices(store: store)
        } catch {
            fatalError("Cannot open ~/.meepo/meepo.sqlite: \(error)")
        }
    }

    /// Demo mode's own ~/.claude and ~/.meepo in a temp folder, starting from a copy of the user's settings (so the
    /// hook bridge shows as it is): Make a button, New command, VOICE… write there, never to the real ones.
    private static func demoBridge() -> BridgeInstaller {
        let home = FileManager.default.temporaryDirectory.appending(path: "meepo-demo-home")
        try? FileManager.default.removeItem(at: home)
        let settings = home.appending(path: ".claude/settings.json")
        try? FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: BridgeInstaller().settingsURL, to: settings)
        return BridgeInstaller(settingsURL: settings, meepoHome: home.appending(path: ".meepo"))
    }

    var body: some Scene {
        Window("meepo", id: "main") {
            MainView()
                .environment(store)
                .onOpenURL { url in
                    store.openFromCommandLine(url)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onChange(of: store.screenshotHotKey) { services?.bindScreenshotHotKey(store.screenshotHotKey, store: store) }
                .task {
                    store.applyAppearance()
                    if Demo.isOn { await store.loadDemo(); return }
                    guard let services else { return }
                    // Asking in App.init is too early: macOS answers "not allowed" before launch finishes.
                    await services.requestNotificationPermission(store: store)
                    services.bindScreenshotHotKey(store.screenshotHotKey, store: store)
                    await store.restoreSessions()
                    store.openDatabaseTunnels() // needs the login environment: ssh-agent's socket
                    Task { // off the launch path: transcripts and git for every folder take a moment
                        await store.refreshTitles()
                        await store.refreshWork()
                    }
                    await store.refreshSuggestions()
                    await store.tidyStagesOnce()
                    quitHandler.store = store
                    store.terminate = { NSApp.terminate(nil) }
                    Task { // Updates like Claude Code: at launch, then every 6 hours; installed at quit.
                        while !Task.isCancelled {
                            await store.checkForUpdates()
                            try? await Task.sleep(for: .seconds(3600)) // hourly: betas come out more than once a day
                        }
                    }
                    Task { // Teammates' commits: every 5 minutes, and when the user comes back to Meepo.
                        let activations = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
                        Task {
                            for await _ in activations {
                                await store.autoSync()
                                await store.refreshWork() // every folder, not only the running sessions' ones
                                await store.checkForUpdatesIfStale()
                            }
                        }
                        while !Task.isCancelled {
                            await store.autoSync()
                            try? await Task.sleep(for: .seconds(300))
                        }
                    }
                    Task { // Sessions outside meepo: every 15 s, and when the user comes back to meepo.
                        let activations = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
                        Task { for await _ in activations { await store.refreshElsewhere() } }
                        while !Task.isCancelled {
                            await store.refreshElsewhere()
                            try? await Task.sleep(for: .seconds(15))
                        }
                    }
                    Task { // Once a minute is cheap on the GitHub API; every 15 s while a step runs, so it looks live.
                        while !Task.isCancelled {
                            await store.refreshCI()
                            try? await Task.sleep(for: .seconds(store.isCIRunning ? 15 : 60))
                        }
                    }
                    // JSONL is appended continuously; Stop events also trigger a refresh.
                    while !Task.isCancelled {
                        await store.refreshUsage()
                        store.refreshVoice() // /voice typed in a session changes ~/.claude/settings.json
                        store.publishWidgetSnapshot()
                        try? await Task.sleep(for: .seconds(10))
                    }
                }
        }
        // Own Win95-style title bar in MainView instead of the system one (design §5).
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                if store.isBridgeInstalled {
                    Button("Remove Hook Bridge") { store.uninstallBridge() }
                } else {
                    Button("Install Hook Bridge") { store.installBridge() }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Session") { store.presentNewSession() }
                    .keyboardShortcut("n")
                    .disabled(store.projects.isEmpty)
            }
            CommandGroup(replacing: .appSettings) { SettingsCommand(store: store) }
            CommandMenu("Sessions") {
                ForEach(1...9, id: \.self) { number in
                    Button("Session \(number)") { store.selectSession(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                }
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(store)
        } label: {
            // Badge: sessions waiting for the user.
            let waiting = store.waitingCount
            HStack {
                Image(nsImage: MenuBarIcon.mark)
                if waiting > 0 { Text("\(waiting)") }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// ⌘,: Settings is a sheet in the window, not a window of its own. Opens the window if it was closed;
/// over another sheet it only beeps (a second sheet can't stack on the first).
private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    let store: AppStore

    var body: some View {
        Button("Settings…") {
            openWindow(id: "main") // brings it back when closed, to the front otherwise
            guard !store.isSettingsShown else { return }
            if NSApp.windows.contains(where: { $0.attachedSheet != nil }) { NSSound.beep() } else { store.isSettingsShown = true }
        }
        .keyboardShortcut(",")
    }
}

/// Event server and notifications; not created while unit tests host the app.
@MainActor
final class LiveServices {
    private let notifier = Notifier()
    private var server: EventServer?
    private let screenshots: ScreenshotFlow
    private var shotHotKey: GlobalHotKey?

    /// (Re)binds the screenshot hotkey from Settings.
    func bindScreenshotHotKey(_ title: String, store: AppStore) {
        shotHotKey?.unregister()
        shotHotKey = GlobalHotKey.combos.first { $0.title == title }.map { combo in
            GlobalHotKey(combo) { [weak self] in self?.screenshots.start() }
        }
        if let status = shotHotKey?.status, status != noErr {
            store.bridgeError = "Screenshot hotkey \(title) is taken (error \(status)). Pick another in Settings."
        }
    }

    func requestNotificationPermission(store: AppStore) async {
        store.notificationsAllowed = await notifier.requestAuthorization()
    }

    init(store: AppStore) {
        screenshots = ScreenshotFlow(store: store)
        // The user may have just turned notifications on in System Settings and come back.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self, weak store] _ in
            MainActor.assumeIsolated {
                guard let self, let store else { return }
                Task { store.notificationsAllowed = await self.notifier.isAuthorized() }
            }
        }
        store.refreshBridge()
        store.onCINotice = { [weak self] title, body in self?.notifier.postText(title, body) }
        notifier.onOpen = { [weak store] id in
            store?.selectedSessionId = id
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        do {
            let server = EventServer(token: try MeepoHome.token()) { [weak self, weak store] sessionId, body in
                guard let store else { return }
                if let status = StatusLine(json: body) { store.applyStatusLine(status, sessionId: sessionId); return }
                guard let payload = HookPayload(json: body) else { return }
                let attention = store.handleHookEvent(payload, sessionId: sessionId)
                if payload.event == "Stop" { Task { await store.refreshUsage() } }
                guard let attention,
                      let session = store.sessions.first(where: { $0.id == sessionId }) else { return }
                // The user is already looking at this session's terminal (split views show several).
                if NSApp.isActive && store.visibleSessionIds.contains(sessionId) { return }
                self?.notifier.post(attention, session: session, project: store.project(for: session),
                                    summary: payload.summary)
            }
            server.onFailure = { [weak store] message in store?.bridgeError = message }
            server.reply = { [weak store] sessionId, body in store?.hookReply(sessionId: sessionId, body: body) }
            try server.start()
            self.server = server
        } catch {
            store.bridgeError = error.localizedDescription
        }
    }
}

/// Installs a downloaded update as Meepo quits, so it's the new version next time (like Claude Code).
final class QuitHandler: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    /// Every quit — ⌘Q, the menu bar, RESTART — asks first when agents are mid-turn.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let store, !store.shouldQuit() else { return .terminateNow }
            NSApp.activate(ignoringOtherApps: true)
            // A sheet (Stats, Tools, Automations…) would cover the question drawn in the window: ask as macOS does.
            if NSApp.windows.contains(where: { $0.attachedSheet != nil }), let question = store.confirmation {
                store.confirmation = nil
                return Self.ask(question) ? .terminateNow : .terminateCancel
            }
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) // where the question is
            return .terminateCancel
        }
    }

    /// The quit question as a system alert, on top of everything. True: quit now.
    @MainActor
    private static func ask(_ question: PixelConfirmation) -> Bool {
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message ?? ""
        alert.addButton(withTitle: question.action)
        if let alternative = question.alternative { alert.addButton(withTitle: alternative.title) }
        alert.addButton(withTitle: question.cancel ?? "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true // not perform(): it calls terminate, and this is already the answer to one
        case .alertSecondButtonReturn where question.alternative != nil:
            question.alternative?.perform()
            return false
        default:
            question.onCancel?()
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let store else { return }
            store.closeTunnels() // no ssh left behind
            let updated = store.installStagedUpdate()
            if store.relaunchAfterQuit, updated { Updater.relaunch(Bundle.main.bundleURL) }
        }
    }
}
