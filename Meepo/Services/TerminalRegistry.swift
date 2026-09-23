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

    func start(_ session: Session, in directory: String, initialPrompt: String?,
               login: ClaudeLauncher.LoginEnvironment?) {
        guard let id = session.id, views[id] == nil else { return }
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.processDelegate = self
        let args = ClaudeLauncher.claudeArguments(
            sessionId: session.claudeSessionId,
            resume: ClaudeLauncher.hasTranscript(sessionId: session.claudeSessionId),
            model: session.model,
            prompt: initialPrompt
        )
        // Lets meepo-bridge.sh tag every hook event with this session, even after /clear changes the claude id.
        let meepo = ["MEEPO_SESSION_ID": String(id), "MEEPO_PORT": String(EventServer.defaultPort)]
        if let login {
            view.startProcess(executable: login.claudePath, args: args,
                              environment: ClaudeLauncher.environment(base: login.environment, extra: meepo),
                              currentDirectory: directory)
        } else {
            let launch = ClaudeLauncher.shellLaunch(claudeArgs: args)
            view.startProcess(executable: launch.executable, args: launch.args,
                              environment: ClaudeLauncher.environment(
                                  base: ClaudeLauncher.scrubbed(ProcessInfo.processInfo.environment), extra: meepo),
                              currentDirectory: directory)
        }
        views[id] = view
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
