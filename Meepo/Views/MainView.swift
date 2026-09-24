import SwiftTerm
import SwiftUI

/// One Win95-style window (design §5): own title bar, then sidebar | terminal | feed,
/// each panel in a pixel frame on the grey window body. No system sidebar/inspector:
/// on macOS 26 those float as rounded glass panels.
struct MainView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("feedShown") private var isFeedShown = true
    @State private var isPickingFolder = false
    @State private var addError: String?
    @State private var isStatsShown = false
    @State private var isMorningShown = false
    @State private var isDayShown = false
    @State private var isToolsShown = false
    @State private var isNotesShown = false
    @State private var isImportShown = false
    @AppStorage("onboarded") private var isOnboarded = false

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(isFeedShown: $isFeedShown, isStatsShown: $isStatsShown,
                     isMorningShown: $isMorningShown, isDayShown: $isDayShown, isToolsShown: $isToolsShown,
                     isNotesShown: $isNotesShown, isImportShown: $isImportShown) { isPickingFolder = true }
            HStack(spacing: 6) {
                SidebarView()
                    .frame(width: 290)
                    .pixelFrame(4)
                Group {
                    if let id = store.selectedSessionId {
                        SessionDetailView(sessionId: id)
                    } else {
                        EmptyStateView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.grassDeep)
                .pixelFrame(4)
                if isFeedShown {
                    EventFeedView()
                        .frame(width: 300)
                        .pixelFrame(4)
                }
            }
            .padding(6)
        }
        .background(Tokens.frameMid)
        .overlay(Bevel(raised: true))
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 520)
        .preferredColorScheme(.dark)
        .sheet(isPresented: Binding(
            get: { store.newSessionProjectId != nil },
            set: { if !$0 { store.newSessionProjectId = nil } }
        )) {
            NewSessionSheet()
        }
        .sheet(isPresented: $isStatsShown) { StatsView() }
        .sheet(isPresented: $isMorningShown) { MorningView() }
        .sheet(isPresented: $isDayShown) { DayView() }
        .sheet(isPresented: $isToolsShown) { ToolsView() }
        .sheet(isPresented: $isNotesShown) { NotesView() }
        .sheet(isPresented: $isImportShown) { ImportView() }
        .sheet(isPresented: Binding(get: { !isOnboarded }, set: { if !$0 { isOnboarded = true } })) { OnboardingView() }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            do {
                try store.addProject(at: result.get())
            } catch {
                addError = error.localizedDescription
            }
        }
        .alert("Couldn’t add the project", isPresented: Binding(
            get: { addError != nil },
            set: { if !$0 { addError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addError ?? "")
        }
    }
}

/// Grey title strip; leaves room for the traffic lights and drags the window like a real title bar.
private struct TitleBar: View {
    @Environment(AppStore.self) private var store
    @Binding var isFeedShown: Bool
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
            Text("MEEPO")
                .font(Fonts.title(16))
                .foregroundStyle(Tokens.text)
            PixelMenu(selection: "+ Project") {
                Button("Folder…", action: onAddProject)
                Button("From VS Code, Cursor, Windsurf…") { isImportShown = true }
            }
            .padding(.leading, 12)
            Button(isFeedShown ? "Hide Events" : "Events") { isFeedShown.toggle() }
            Button("Morning") { isMorningShown = true }
                .help("Start today's sessions from the task list")
            Button("Day") { isDayShown = true }
                .help("End-of-day summary per project")
            Button("Stats") { isStatsShown = true }
            Button("Tools") { isToolsShown = true }
                .help("Shared commands/hooks across projects, Docker cleanup")
            Button("Notes") { isNotesShown = true }
                .help("Release note drafts from recent commits, in your voice")
            SettingsLink { Text("Settings") }
                .help("Context windows, relay threshold, Remote Control, stages (⌘,)")
            if store.waitingCount > 0 {
                Text("! \(store.waitingCount)")
                    .font(Fonts.title(16))
                    .foregroundStyle(Tokens.alert)
                    .help("Sessions waiting for you: \(store.waitingCount) — Ctrl+Tab")
            }
            Spacer()
            if let update = store.availableUpdate, let url = URL(string: update.html_url) {
                Link("UPDATE \(update.version)", destination: url)
                    .font(Fonts.title(16))
                    .foregroundStyle(Tokens.selection)
                    .help("brew upgrade --cask meepo, or download it from the release page")
            }
        }
        .buttonStyle(PixelButtonStyle())
        .padding(.leading, isFullScreen ? 8 : 80) // room for the traffic lights, which full screen hides
        .padding(.trailing, 8)
        .frame(height: 38)
        .background(WindowDragArea())
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = false }
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

private struct SessionDetailView: View {
    @Environment(AppStore.self) private var store
    let sessionId: Int64

    var body: some View {
        VStack(spacing: 0) {
            terminal
            if let session = store.sessions.first(where: { $0.id == sessionId }) {
                StagePanel(session: session)
            }
        }
        // Launch lazily when a session is first shown (also after Meepo restarts).
        .task(id: sessionId) { store.startTerminalIfNeeded(sessionId) }
    }

    private var terminal: some View {
        ZStack(alignment: .bottom) {
            Tokens.terminalBg
            if let view = store.terminalView(for: sessionId), store.runningSessionIds.contains(sessionId) || store.exitedSessionIds.contains(sessionId) {
                TerminalHost(terminal: view)
                    .padding(6)
            }
            if store.exitedSessionIds.contains(sessionId) {
                HStack {
                    Text("Session exited")
                        .foregroundStyle(Tokens.text)
                    Button("Continue") { store.restartSession(sessionId) }
                        .buttonStyle(PixelButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
                .pixelFrame(6)
                .padding()
            }
        }
        // Terminal sits in a pressed-in well (design §5).
        .sunken()
    }
}

/// No session selected: the idle unit by its switched-off terminal (assets/ref/empty.png) and one button.
private struct EmptyStateView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Image("EmptyState")
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 520)
                .pixelFrame(6)
            if store.projects.isEmpty {
                Text("Add a project with “+ Project” above")
                    .foregroundStyle(Tokens.textDim)
            } else {
                Button("Start Session") { store.presentNewSession() }
                    .buttonStyle(PixelButtonStyle(large: true))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        terminal.needsLayout = true
        terminal.needsDisplay = true
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
    }
}
