import GRDB
import SwiftUI

@main
struct MeepoApp: App {
    @State private var store: AppStore
    private let hotkeys: HotkeyMonitor
    /// Unit tests host the app: keep them off the real database and away from real sessions.
    private let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        do {
            let db = isTesting ? try DatabaseQueue() : try AppDatabase.openShared()
            if isTesting { try AppDatabase.migrator.migrate(db) }
            let store = AppStore(db: db)
            _store = State(initialValue: store)
            hotkeys = HotkeyMonitor(store: store)
        } catch {
            fatalError("Cannot open ~/.meepo/meepo.sqlite: \(error)")
        }
    }

    var body: some Scene {
        Window("Meepo", id: "main") {
            MainView()
                .environment(store)
                .task { if !isTesting { await store.restoreSessions() } }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новая сессия") { store.presentNewSession() }
                    .keyboardShortcut("n")
                    .disabled(store.projects.isEmpty)
            }
            CommandMenu("Сессии") {
                ForEach(1...9, id: \.self) { number in
                    Button("Сессия \(number)") { store.selectSession(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                }
            }
        }

        MenuBarExtra("Meepo", systemImage: "square.stack.3d.up") {
            MenuBarPanel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)
    }
}
