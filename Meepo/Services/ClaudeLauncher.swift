import Foundation
import os

/// Builds the command line for a `claude` session. Flags verified against `claude --help` (v2.1.280).
enum ClaudeLauncher {
    /// Settings only Meepo's sessions get (`--settings` outranks the user's files and changes nothing on disk):
    /// the light theme for Meepo's paper-light terminals, ultracode when that's the chosen effort —
    /// ultracode is a setting, not an `--effort` value (2.1.282 accepts low…max there) — and the statusline.
    /// `statusLine`: Meepo's statusline command, when the bridge is there to receive it.
    static func sessionSettings(effort: String?, statusLine: String? = nil, guided: Bool = false) -> [String] {
        var settings: [String: Any] = ["theme": "light"]
        if effort == ultracode { settings["ultracode"] = true }
        if guided {
            settings["outputStyle"] = "Explanatory"
            settings["permissions"] = ["ask": guidedAsks]
        }
        if let statusLine { settings["statusLine"] = ["type": "command", "command": statusLine, "padding": 0] }
        let json = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? #"{"theme":"light"}"#
        return ["--settings", json]
    }

    /// Guided mode (people new to Claude Code): Claude explains what it does, and asks before anything hard to
    /// take back — even in auto mode (`permissions.ask` holds there since 2.1.28x). Not `--safe-mode`, which
    /// turns hooks off, Meepo's bridge included. Read once, when claude starts (`--settings` is pinned then),
    /// so a running session changes mode only by restarting; /output-style would write the project's
    /// .claude/settings.local.json instead of switching only meepo's session.
    static let guidedAsks = ["Bash(git push:*)", "Bash(git reset --hard:*)", "Bash(rm -rf:*)", "Bash(sudo:*)",
                             "Bash(npm publish:*)", "Edit(**/.env*)"]

    static let ultracode = "ultracode"
    /// "" = Claude Code's default.
    static let effortLevels = ["", "low", "medium", "high", "xhigh", "max", ultracode]

    /// New session: `--session-id <uuid>` so Meepo knows the id up front.
    /// Existing transcript: `--resume <uuid>`; the initial prompt is never re-sent.
    /// `remoteControl`: session name shown in the Claude app / claude.ai (`--remote-control <name>`),
    /// so the session can be followed and answered from the phone. Verified on 2.1.280.
    /// `claude auth status` → signed in or not, and how; nil when it can't tell. Blocking; call off the main thread.
    static func authStatus(login: LoginEnvironment) -> AuthStatus? {
        let process = Process()
        process.executableURL = URL(filePath: login.claudePath)
        process.arguments = ["auth", "status"]
        process.environment = login.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        return AuthStatus(json: data)
    }

    /// `method` is Claude Code's authMethod (2.1.283): "claude.ai", "oauth_token", "api_key", "api_key_helper",
    /// "third_party" (Bedrock, Vertex…) or "none".
    struct AuthStatus: Equatable, Sendable {
        var loggedIn: Bool
        var method: String?

        init(loggedIn: Bool, method: String?) {
            self.loggedIn = loggedIn
            self.method = method
        }

        init?(json: Data) {
            guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let loggedIn = obj["loggedIn"] as? Bool else { return nil }
            self.init(loggedIn: loggedIn, method: obj["authMethod"] as? String)
        }
    }

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
        process.waitForExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").first.map(String.init)
    }

    static func claudeArguments(sessionId: String, resume: Bool, model: String?, effort: String? = nil,
                                worktree: String? = nil, remoteControl: String? = nil, prompt: String?,
                                name: String? = nil, addDirs: [String] = []) -> [String] {
        // --add-dir takes several values: first, so the next option (not the prompt) ends its list.
        var args = addDirs.isEmpty ? [] : ["--add-dir"] + addDirs
        args += resume ? ["--resume", sessionId] : ["--session-id", sessionId]
        if let name, !name.isEmpty { args += ["--name", name] }  // shown in the prompt box, /resume, Remote Control
        if let worktree { args += ["--worktree", worktree] }
        if let remoteControl { args += ["--remote-control", remoteControl] }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let effort, !effort.isEmpty, effort != ultracode { args += ["--effort", effort] }
        // claude reads any argument starting with "-" as an option ("- add login…" → unknown option):
        // `--` makes the prompt its [prompt] operand. Stays last — anything after `--` is prompt, not options.
        if !resume, let prompt, !prompt.isEmpty { args += ["--", prompt] }
        return args
    }

    /// A background agent in a meepo tab: its own settings, model and effort stay as it was started with.
    /// Closing the tab only lets go of it — "The session keeps running either way" (`claude attach --help`, 2.1.283).
    static func attachArguments(agentId: String) -> [String] { ["attach", agentId] }

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
    /// At `timeout` the shell's process group gets TERM (ends a stuck command, the shell carries on), then KILL
    /// 2 s later: interactive shells ignore TERM. The read ends at the last marker, not at EOF, which a job
    /// ~/.zshrc started in the background would hold off for as long as it runs.
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
        // Process gives the shell its own group (pgid == pid), so -pid also reaches what ~/.zshrc started.
        let pid = process.processIdentifier
        let reading = OSAllocatedUnfairLock(initialState: true) // no signals once done: the pid may be reused
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard reading.withLock({ $0 }) else { return }
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                guard reading.withLock({ $0 }) else { return }
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
        let handle = out.fileHandleForReading
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        // POSIX read returns what has arrived; FileHandle.read(upToCount:) waits for the full count or EOF.
        while String(decoding: data, as: UTF8.self).components(separatedBy: loginMarker).count < 4 {
            let n = read(handle.fileDescriptor, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            data.append(contentsOf: buffer[..<n])
        }
        reading.withLock { $0 = false }
        try? handle.close()
        // No waitForExit: a hanging ~/.zlogout would block after a good read; Foundation reaps the shell.
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
