import AppKit
import SwiftTerm

/// Keeps one live terminal per session so switching sessions never restarts `claude`.
@MainActor
final class TerminalRegistry: NSObject, LocalProcessTerminalViewDelegate {
    private var views: [Int64: LocalProcessTerminalView] = [:]
    var onExit: ((Int64) -> Void)?
    /// The app turned light or dark (Settings → Appearance, or macOS at sunset): true = dark now.
    var onAppearanceChange: ((Bool) -> Void)?
    private var appearanceObservation: NSKeyValueObservation?
    private var wasDark = false

    /// Once the app runs: in App.init, where the registry is made, NSApp is still nil and nothing could be observed.
    func observeAppearance() {
        guard appearanceObservation == nil, let app = NSApp else { return }
        wasDark = Self.isDark
        appearanceObservation = app.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.appearanceChanged() }
        }
        for view in views.values { paint(view) } // any made before the app's appearance was set
    }

    /// What the app draws in now; claude starts in the matching theme.
    static var isDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// SwiftTerm turns a color into its own when it's set, so every terminal is told again.
    private func appearanceChanged() {
        guard Self.isDark != wasDark else { return }
        wasDark = Self.isDark
        for view in views.values { paint(view) }
        onAppearanceChange?(wasDark)
    }

    private func paint(_ view: LocalProcessTerminalView) {
        view.nativeBackgroundColor = Self.resolved(Tokens.Terminal.background)
        view.nativeForegroundColor = Self.resolved(Tokens.Terminal.foreground)
        view.caretColor = Self.resolved(Tokens.Terminal.caret)
        view.needsDisplay = true
    }

    /// A light/dark color fixed to the app's current look.
    private static func resolved(_ color: NSColor) -> NSColor {
        var fixed = color
        (NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
            fixed = color.usingColorSpace(.sRGB) ?? color
        }
        return fixed
    }

    func view(for sessionId: Int64) -> LocalProcessTerminalView? {
        views[sessionId]
    }

    func start(_ session: Session, projectPath: String, initialPrompt: String?,
               login: ClaudeLauncher.LoginEnvironment, remoteControlName: String? = nil, guided: Bool = false,
               asks: [String] = [], attach agentId: String? = nil, mod: URL? = nil) {
        guard let id = session.id, views[id] == nil else { return }
        var (directory, createWorktree) = ClaudeLauncher.location(worktreeName: session.worktreeName, projectPath: projectPath)
        if let folder = session.folder, FileManager.default.fileExists(atPath: folder) { directory = folder }
        let view = makeView()
        let bridge = BridgeInstaller()
        let hasBridge = FileManager.default.isExecutableFile(atPath: bridge.scriptURL.path)
        let args = if let agentId { ClaudeLauncher.attachArguments(agentId: agentId) } else {
            ClaudeLauncher.sessionSettings(effort: session.effort,
                                                  statusLine: hasBridge ? bridge.statusLineCommand : nil,
                                                  guided: guided, dark: Self.isDark, asks: asks)
            + (mod.map { ["--plugin-dir", $0.path] } ?? [])
            + ClaudeLauncher.claudeArguments(
            sessionId: session.claudeSessionId,
            resume: ClaudeLauncher.hasTranscript(sessionId: session.claudeSessionId),
            model: session.model,
            effort: session.effort,
            worktree: createWorktree,
            remoteControl: remoteControlName,
            prompt: initialPrompt,
            name: session.name,
            addDirs: (session.extraDirs ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        )
        }
        // Lets meepo-bridge.sh tag every hook event with this session, even after /clear changes the claude id.
        var meepo = ["MEEPO_SESSION_ID": String(id), "MEEPO_PORT": String(EventServer.defaultPort)]
        if hasBridge, let own = bridge.userStatusLine() { meepo["MEEPO_USER_STATUSLINE"] = own }
        if mod != nil { meepo["MEEPO_MOD"] = "1" } // the bridge script steps aside: the mod forwards the events
        if let base = session.portBase { // SPEC module 5: the session's own port range
            meepo["PORT"] = String(base)
            meepo["MEEPO_PORT_BASE"] = String(base)
        }
        view.startProcess(executable: login.claudePath, args: args,
                          environment: ClaudeLauncher.environment(base: login.environment, extra: meepo),
                          currentDirectory: directory)
        views[id] = view
    }

    /// A shell in the session's terminal — `ssh <host>`, or the user's own shell — with the login environment
    /// (ssh-agent's socket, PATH from ~/.zshrc).
    func startShell(_ session: Session, executable: String, arguments: [String], environment: [String: String], directory: String) {
        guard let id = session.id, views[id] == nil else { return }
        let view = makeView()
        view.startProcess(executable: executable, args: arguments,
                          environment: ClaudeLauncher.environment(base: environment), currentDirectory: directory)
        views[id] = view
    }

    /// Sessions start before they're on screen; a zero frame would start the process in a 0-column terminal.
    private func makeView(width: CGFloat = 1000) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
        view.font = Fonts.terminal(13)
        paint(view)
        view.processDelegate = self
        return view
    }

    /// Demo mode: a terminal that shows a fixed page and runs nothing.
    func showText(_ text: String, for sessionId: Int64) {
        // About a pane's width: SwiftTerm wraps text when it's fed and doesn't reflow it later.
        let view = makeView(width: 700)
        view.feed(text: text)
        views[sessionId] = view
    }

    /// Demo story: more of a fixed page, fed to the terminal already on screen.
    func feedText(_ text: String, for sessionId: Int64) {
        views[sessionId]?.feed(text: text)
    }

    /// Types into the session's terminal as if the user did ("\r" = Enter).
    func send(_ text: String, to sessionId: Int64) {
        views[sessionId]?.send(txt: text)
    }

    func close(_ sessionId: Int64) {
        views.removeValue(forKey: sessionId)?.terminate()
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let ref = ObjectIdentifier(source)
        Task { @MainActor in
            guard let id = self.views.first(where: { ObjectIdentifier($0.value) == ref })?.key else { return }
            self.onExit?(id)
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
