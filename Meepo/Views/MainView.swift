import SwiftTerm
import SwiftUI

struct MainView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            Group {
                if let id = store.selectedSessionId {
                    SessionDetailView(sessionId: id)
                } else {
                    Text(store.projects.isEmpty ? "Добавьте проект кнопкой +" : "Создайте сессию: ⌘N")
                        .foregroundStyle(Tokens.text.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Tokens.background)
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: Binding(
            get: { store.newSessionProjectId != nil },
            set: { if !$0 { store.newSessionProjectId = nil } }
        )) {
            NewSessionSheet()
        }
    }
}

private struct SessionDetailView: View {
    @Environment(AppStore.self) private var store
    let sessionId: Int64

    var body: some View {
        ZStack(alignment: .bottom) {
            if let view = store.terminalView(for: sessionId), store.runningSessionIds.contains(sessionId) || store.exitedSessionIds.contains(sessionId) {
                TerminalHost(terminal: view)
            }
            if store.exitedSessionIds.contains(sessionId) {
                HStack {
                    Text("Сессия завершена")
                    Button("Продолжить") { store.restartSession(sessionId) }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(10)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 8))
                .padding()
            }
        }
        // Launch lazily when a session is first shown (also after Meepo restarts).
        .task(id: sessionId) { store.startTerminalIfNeeded(sessionId) }
    }
}

/// Hosts a cached terminal view; swapping views keeps every session's process alive.
private struct TerminalHost: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard container.subviews.first !== terminal else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
    }
}
