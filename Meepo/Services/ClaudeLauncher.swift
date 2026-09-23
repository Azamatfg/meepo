import Foundation

/// Builds the command line for a `claude` session. Flags verified against `claude --help` (v2.1.280).
enum ClaudeLauncher {
    struct Launch: Equatable {
        let executable: String
        let args: [String]
    }

    /// New session: `--session-id <uuid>` so Meepo knows the id up front.
    /// Existing transcript: `--resume <uuid>`; the initial prompt is never re-sent.
    /// `remoteControl`: session name shown in the Claude app / claude.ai (`--remote-control <name>`),
    /// so the session can be followed and answered from the phone. Verified on 2.1.280.
    static func claudeArguments(sessionId: String, resume: Bool, model: String?, effort: String? = nil,
                                worktree: String? = nil, remoteControl: String? = nil, prompt: String?) -> [String] {
        var args = resume ? ["--resume", sessionId] : ["--session-id", sessionId]
        if let worktree { args += ["--worktree", worktree] }
        if let remoteControl { args += ["--remote-control", remoteControl] }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let effort, !effort.isEmpty { args += ["--effort", effort] }
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
    /// Blocking; call off the main thread. Nil if the shell fails or has no `claude`.
    static func resolveLoginEnvironment(shell: String = defaultShell) -> LoginEnvironment? {
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

    /// Fallback when the login environment isn't resolved (yet): pay for a shell start per session.
    static func shellLaunch(claudeArgs: [String], shell: String = defaultShell) -> Launch {
        let command = (["exec", "claude"] + claudeArgs.map(shellQuote)).joined(separator: " ")
        return Launch(executable: shell, args: ["-l", "-i", "-c", command])
    }

    static var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
