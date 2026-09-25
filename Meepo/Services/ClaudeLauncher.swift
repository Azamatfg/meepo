import Foundation

/// Builds the command line for a `claude` session. Flags verified against `claude --help` (v2.1.280).
enum ClaudeLauncher {
    /// Settings only Meepo's sessions get (`--settings` outranks the user's files and changes nothing on disk):
    /// the light theme for Meepo's paper-light terminals, ultracode when that's the chosen effort —
    /// ultracode is a setting, not an `--effort` value (2.1.282 accepts low…max there) — and the statusline.
    /// `statusLine`: Meepo's statusline command, when the bridge is there to receive it.
    static func sessionSettings(effort: String?, statusLine: String? = nil) -> [String] {
        var settings: [String: Any] = ["theme": "light"]
        if effort == ultracode { settings["ultracode"] = true }
        if let statusLine { settings["statusLine"] = ["type": "command", "command": statusLine, "padding": 0] }
        let json = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? #"{"theme":"light"}"#
        return ["--settings", json]
    }

    static let ultracode = "ultracode"
    /// "" = Claude Code's default.
    static let effortLevels = ["", "low", "medium", "high", "xhigh", "max", ultracode]

    /// New session: `--session-id <uuid>` so Meepo knows the id up front.
    /// Existing transcript: `--resume <uuid>`; the initial prompt is never re-sent.
    /// `remoteControl`: session name shown in the Claude app / claude.ai (`--remote-control <name>`),
    /// so the session can be followed and answered from the phone. Verified on 2.1.280.
    /// `claude --version`'s first line, e.g. "2.1.282 (Claude Code)". Blocking; call off the main thread.
    static func versionOutput(login: LoginEnvironment) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: login.claudePath)
        process.arguments = ["--version"]
        process.environment = login.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").first.map(String.init)
    }

    static func claudeArguments(sessionId: String, resume: Bool, model: String?, effort: String? = nil,
                                worktree: String? = nil, remoteControl: String? = nil, prompt: String?) -> [String] {
        var args = resume ? ["--resume", sessionId] : ["--session-id", sessionId]
        if let worktree { args += ["--worktree", worktree] }
        if let remoteControl { args += ["--remote-control", remoteControl] }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let effort, !effort.isEmpty, effort != ultracode { args += ["--effort", effort] }
        if !resume, let prompt, !prompt.isEmpty { args.append(prompt) }
        return args
    }

    /// Where claude runs and whether it must create the worktree: `claude -w` makes
    /// `<repo>/.claude/worktrees/<name>` (branch `worktree-<name>`) on first start, honouring the user's
    /// worktree settings and hooks; afterwards the session runs inside that folder (its transcript lives there).
    static func location(worktreeName: String?, projectPath: String) -> (directory: String, createWorktree: String?) {
        guard let name = worktreeName else { return (projectPath, nil) }
        let path = worktreePath(name, projectPath: projectPath)
        return FileManager.default.fileExists(atPath: path) ? (path, nil) : (projectPath, name)
    }

    static func worktreePath(_ name: String, projectPath: String) -> String {
        URL(filePath: projectPath).appending(path: ".claude/worktrees/\(name)").path
    }

    /// Feature name → safe worktree/branch name: "Login via Google!" → "login-via-google".
    static func worktreeSlug(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// What the user's interactive login shell sees: GUI apps don't inherit PATH,
    /// and tools like nvm are only set up in ~/.zshrc.
    struct LoginEnvironment: Equatable, Sendable {
        let claudePath: String
        let environment: [String: String]
    }

    /// Asks the login shell once (~0.6 s with nvm) so every session can exec claude directly.
    /// Blocking; call off the main thread. Nil if the shell fails, has no `claude`, or hangs past `timeout`
    /// (a ~/.zshrc waiting for input would otherwise leave every session an empty terminal forever).
    static func resolveLoginEnvironment(shell: String = defaultShell, timeout: TimeInterval = 15) -> LoginEnvironment? {
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-l", "-i", "-c",
                             "printf \(loginMarker); command -v claude; printf \(loginMarker); env -0; printf \(loginMarker)"]
        process.environment = scrubbed(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseLoginEnvironment(String(decoding: data, as: UTF8.self))
    }

    static let loginMarker = "__MEEPO_ENV__"

    /// Markers fence off our output from anything ~/.zshrc prints.
    static func parseLoginEnvironment(_ output: String) -> LoginEnvironment? {
        let parts = output.components(separatedBy: loginMarker)
        guard parts.count >= 4 else { return nil }
        let claudePath = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard claudePath.hasPrefix("/") else { return nil } // `command -v` gives an alias/function otherwise
        var env: [String: String] = [:]
        for entry in parts[2].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return LoginEnvironment(claudePath: claudePath, environment: env)
    }

    static var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Drops what Meepo inherits from the terminal it was launched from (Finder launches have none of it):
    /// - Claude Code's session markers, e.g. `CLAUDE_CODE_CHILD_SESSION` turns off transcripts and breaks `--resume`;
    /// - the host terminal's identity (`TERM_PROGRAM=vscode`, `VSCODE_*`), which makes claude try to install
    ///   its IDE extension, and `GIT_ASKPASS` pointing at VS Code's helper.
    /// Applied before the login shell runs, so anything ~/.zshrc sets (incl. CLAUDE_*) survives.
    static func scrubbed(_ env: [String: String]) -> [String: String] {
        let prefixes = ["CLAUDE", "TERM_PROGRAM", "VSCODE_", "CURSOR_"]
        let keys: Set = ["AI_AGENT", "GIT_ASKPASS"]
        return env.filter { entry in !keys.contains(entry.key) && !prefixes.contains { entry.key.hasPrefix($0) } }
    }

    /// `extra` carries MEEPO_SESSION_ID / MEEPO_PORT, which hook commands inherit (checked on 2.1.280).
    static func environment(base: [String: String], extra: [String: String] = [:]) -> [String] {
        var env = base.merging(extra) { _, new in new }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Claude Code writes `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` once the conversation has a message.
    /// Searches by uuid across folders instead of re-deriving the folder-name encoding.
    static func hasTranscript(sessionId: String, claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")) -> Bool {
        let projects = claudeHome.appending(path: "projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.contains { FileManager.default.fileExists(atPath: $0.appending(path: "\(sessionId).jsonl").path) }
    }
}
