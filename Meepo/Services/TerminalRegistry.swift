import AppKit
import SwiftTerm

/// Keeps one live terminal per session so switching sessions never restarts `claude`.
@MainActor
final class TerminalRegistry: NSObject, LocalProcessTerminalViewDelegate {
    private var views: [Int64: LocalProcessTerminalView] = [:]
    var onExit: ((Int64) -> Void)?

    func view(for sessionId: Int64) -> LocalProcessTerminalView? {
        views[sessionId]
    }

    func start(_ session: Session, projectPath: String, initialPrompt: String?,
               login: ClaudeLauncher.LoginEnvironment, remoteControlName: String? = nil, guided: Bool = false) {
        guard let id = session.id, views[id] == nil else { return }
        let (directory, createWorktree) = ClaudeLauncher.location(worktreeName: session.worktreeName, projectPath: projectPath)
        // Sessions start before they're on screen; a zero frame would start claude in a 0-column terminal.
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        view.font = Fonts.terminal(13)
        view.nativeBackgroundColor = NSColor(hex: 0xF6F3EC) // Tokens.terminalBg
        view.nativeForegroundColor = NSColor(hex: 0x1B1A17) // Tokens.text
        view.caretColor = NSColor(hex: 0x2140D9)            // Tokens.work
        view.processDelegate = self
        let bridge = BridgeInstaller()
        let hasBridge = FileManager.default.isExecutableFile(atPath: bridge.scriptURL.path)
        let args = ClaudeLauncher.sessionSettings(effort: session.effort,
                                                  statusLine: hasBridge ? bridge.statusLineCommand : nil,
                                                  guided: guided)
            + ClaudeLauncher.claudeArguments(
            sessionId: session.claudeSessionId,
            resume: ClaudeLauncher.hasTranscript(sessionId: session.claudeSessionId),
            model: session.model,
            effort: session.effort,
            worktree: createWorktree,
            remoteControl: remoteControlName,
            prompt: initialPrompt,
            name: session.name
        )
        // Lets meepo-bridge.sh tag every hook event with this session, even after /clear changes the claude id.
        var meepo = ["MEEPO_SESSION_ID": String(id), "MEEPO_PORT": String(EventServer.defaultPort)]
        if hasBridge, let own = bridge.userStatusLine() { meepo["MEEPO_USER_STATUSLINE"] = own }
        if let base = session.portBase { // SPEC module 5: the session's own port range
            meepo["PORT"] = String(base)
            meepo["MEEPO_PORT_BASE"] = String(base)
        }
        view.startProcess(executable: login.claudePath, args: args,
                          environment: ClaudeLauncher.environment(base: login.environment, extra: meepo),
                          currentDirectory: directory)
        views[id] = view
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
