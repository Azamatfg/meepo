import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.sessions.isEmpty {
                Text("Нет активных сессий")
                    .foregroundStyle(Tokens.text.opacity(0.6))
            }
            ForEach(store.orderedSessions) { session in
                Button {
                    store.selectedSessionId = session.id
                    open()
                } label: {
                    SessionLabel(session: session, projectName: store.project(for: session)?.name)
                }
                .buttonStyle(.plain)
            }
            Divider()
            Button("Открыть Meepo") { open() }
            Button("Выйти") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
        .background(Tokens.background)
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
