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

    /// `bridge`: false once Meepo's event server has failed (its port taken, say). The session then runs as if
    /// the bridge weren't installed: its hook events and token never go to whoever holds the port.
    func start(_ session: Session, projectPath: String, initialPrompt: String?,
               login: ClaudeLauncher.LoginEnvironment, remoteControlName: String? = nil, guided: Bool = false,
               attach agentId: String? = nil, bridge withBridge: Bool = true) {
        guard let id = session.id, views[id] == nil else { return }
        var (directory, createWorktree) = ClaudeLauncher.location(worktreeName: session.worktreeName, projectPath: projectPath)
        if let folder = session.folder, FileManager.default.fileExists(atPath: folder) { directory = folder }
        // Sessions start before they're on screen; a zero frame would start claude in a 0-column terminal.
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        view.font = Fonts.terminal(13)
        view.nativeBackgroundColor = NSColor(hex: 0xF6F3EC) // Tokens.terminalBg
        view.nativeForegroundColor = NSColor(hex: 0x1B1A17) // Tokens.text
        view.caretColor = NSColor(hex: 0x2140D9)            // Tokens.work
        view.processDelegate = self
        let bridge = BridgeInstaller()
        let hasBridge = withBridge && FileManager.default.isExecutableFile(atPath: bridge.scriptURL.path)
        let args = if let agentId { ClaudeLauncher.attachArguments(agentId: agentId) } else {
            ClaudeLauncher.sessionSettings(effort: session.effort,
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
            name: session.name,
            addDirs: (session.extraDirs ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        )
        }
        // Lets meepo-bridge.sh tag every hook event with this session, even after /clear changes the claude id.
        // Without the bridge: none, not even inherited (a Meepo started from a Meepo session's terminal).
        let bridgeKeys = ["MEEPO_SESSION_ID", "MEEPO_PORT"]
        var meepo: [String: String] = withBridge ? ["MEEPO_SESSION_ID": String(id), "MEEPO_PORT": String(EventServer.defaultPort)] : [:]
        if hasBridge, let own = bridge.userStatusLine() { meepo["MEEPO_USER_STATUSLINE"] = own }
        if let base = session.portBase { // SPEC module 5: the session's own port range
            meepo["PORT"] = String(base)
            meepo["MEEPO_PORT_BASE"] = String(base)
        }
        let inherited = withBridge ? login.environment : login.environment.filter { !bridgeKeys.contains($0.key) }
        view.startProcess(executable: login.claudePath, args: args,
                          environment: ClaudeLauncher.environment(base: inherited, extra: meepo),
                          currentDirectory: directory)
        views[id] = view
    }

    /// A terminal that shows a fixed page and runs nothing: demo mode, or a session whose folder is missing.
    func showText(_ text: String, for sessionId: Int64) {
        // About a pane's width: SwiftTerm wraps text when it's fed and doesn't reflow it later.
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        view.font = Fonts.terminal(13)
        view.nativeBackgroundColor = NSColor(hex: 0xF6F3EC)
        view.nativeForegroundColor = NSColor(hex: 0x1B1A17)
        view.caretColor = NSColor(hex: 0x2140D9)
        view.feed(text: text)
        views[sessionId] = view
    }

    /// Types into the session's terminal as if the user did ("\r" = Enter).
    func send(_ text: String, to sessionId: Int64) {
        views[sessionId]?.send(txt: text)
    }

    /// SwiftTerm's terminate() sends TERM and cancels its own exit monitor, so nothing would reap claude — and
    /// a zombie's worktree lock looks alive to Claude Code. Reaps it here; the task ends once claude is gone.
    /// `killAfter`: seconds before KILL. Only a caller that waits for it (REMOVE WORKTREE) should shorten it:
    /// claude's own shutdown runs SessionEnd hooks for up to their longest timeout (≤ 60 s), then gives up 5 s later.
    @discardableResult
    func close(_ sessionId: Int64, killAfter seconds: Int = 70) -> Task<Void, Never>? {
        guard let view = views.removeValue(forKey: sessionId) else { return nil }
        // Exited: SwiftTerm already reaped it, so don't signal a pid that may belong to someone else by now.
        guard view.process.running, view.process.shellPid > 0 else { return nil }
        let pid = view.process.shellPid
        view.terminate()
        return Task {
            var status: Int32 = 0
            for attempt in 0..<(seconds + 1) * 20 { // every 50 ms, then ~1 s after KILL
                if waitpid(pid, &status, WNOHANG) != 0 { return } // reaped, or no longer our child
                if attempt == seconds * 20 { kill(pid, SIGKILL) } // still unreaped, so the pid can't have been reused
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
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
