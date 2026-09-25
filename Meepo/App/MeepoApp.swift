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
        Fonts.register()
        do {
            let db = isTesting ? try DatabaseQueue() : try AppDatabase.openShared()
            if isTesting { try AppDatabase.migrator.migrate(db) }
            let store = AppStore(db: db)
            _store = State(initialValue: store)
            hotkeys = HotkeyMonitor(store: store)
            services = isTesting ? nil : LiveServices(store: store)
        } catch {
            fatalError("Cannot open ~/.meepo/meepo.sqlite: \(error)")
        }
    }

    var body: some Scene {
        Window("Meepo", id: "main") {
            MainView()
                .environment(store)
                .onOpenURL { url in
                    store.openFromCommandLine(url)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onChange(of: store.screenshotHotKey) { services?.bindScreenshotHotKey(store.screenshotHotKey, store: store) }
                .task {
                    guard let services else { return }
                    // Asking in App.init is too early: macOS answers "not allowed" before launch finishes.
                    await services.requestNotificationPermission(store: store)
                    services.bindScreenshotHotKey(store.screenshotHotKey, store: store)
                    await store.restoreSessions()
                    await store.refreshSuggestions()
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
                                await store.checkForUpdatesIfStale()
                            }
                        }
                        while !Task.isCancelled {
                            await store.autoSync()
                            try? await Task.sleep(for: .seconds(300))
                        }
                    }
                    Task { // CI changes slowly; once a minute is plenty and cheap on the GitHub API
                        while !Task.isCancelled {
                            await store.refreshCI()
                            try? await Task.sleep(for: .seconds(60))
                        }
                    }
                    // JSONL is appended continuously; Stop events also trigger a refresh.
                    while !Task.isCancelled {
                        await store.refreshUsage()
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
            CommandMenu("Sessions") {
                ForEach(1...9, id: \.self) { number in
                    Button("Session \(number)") { store.selectSession(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                }
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(store)
        } label: {
            // Badge: sessions waiting for the user.
            let waiting = store.waitingCount
            HStack {
                Image(nsImage: MenuBarIcon.hood)
                if waiting > 0 { Text("\(waiting)") }
            }
        }
        .menuBarExtraStyle(.window)
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
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) // where the question is
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let store else { return }
            let updated = store.installStagedUpdate()
            if store.relaunchAfterQuit, updated { Updater.relaunch(Bundle.main.bundleURL) }
        }
    }
}
