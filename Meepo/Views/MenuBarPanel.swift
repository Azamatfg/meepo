import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.sessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(Tokens.textDim)
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
            // All Claude Code usage on this Mac today, like Stats (SPEC §5).
            Text("\(TokenFormat.short(store.usageStats(since: Calendar.current.startOfDay(for: .now)).total.total)) tokens today")
                .font(Fonts.mono(12))
                .foregroundStyle(Tokens.screen)
            HStack {
                Button("Open Meepo") { open() }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(PixelButtonStyle())
        }
        .padding(12)
        .frame(width: 280)
        .background(Tokens.grass)
        .preferredColorScheme(.light)
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
