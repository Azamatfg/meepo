import Darwin
import Foundation

/// Claude sessions meepo didn't start: background agents (`claude --bg`, agent view) and claude open in another
/// window (Terminal, VS Code, iTerm…). Read from `claude agents --json` (2.1.283; no TTY needed).
enum ClaudeAgents {
    struct Agent: Identifiable, Hashable, Sendable {
        /// The background session's short id (what `claude attach|logs|stop` take); else the session id or pid.
        var id: String
        /// "background", "interactive" — anything newer is kept as text.
        var kind: String
        var sessionId: String?
        var cwd: String?
        var name: String?
        /// `state` of a background session ("working", "blocked", "idle"…), `status` of an interactive one ("busy", "idle").
        var state: String?
        var pid: Int32?
        var startedAt: Date?
        /// The app the interactive session runs in: "VS Code", "Terminal"…; nil when it can't be told.
        var host: String?
        /// Its parent processes include meepo: one of meepo's own sessions (also after /clear changed its id).
        var isInsideMeepo = false
        /// An interactive session that was listed earlier in this run and is gone now: its window closed it.
        var endedAt: Date?

        var isBackground: Bool { kind == "background" }
        var isInteractive: Bool { kind == "interactive" }
        /// A blocked background agent waits for the user (a permission, a question).
        var needsYou: Bool { isBackground && state == "blocked" && endedAt == nil }
        /// Continue here takes over the conversation only once no other window runs it: gone from the list (one
        /// listing can miss it) and its process gone too.
        var canContinueHere: Bool { isInteractive && endedAt != nil && sessionId != nil && !isProcessAlive }
        var isProcessAlive: Bool { pid.map { kill($0, 0) == 0 || errno == EPERM } ?? false }
        var folderName: String { cwd.map { URL(filePath: $0).lastPathComponent } ?? "?" }
        var title: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? folderName }
        /// "background", "in VS Code", "in another window".
        var place: String { isBackground ? "background" : isInteractive ? "in \(host ?? "another window")" : kind }

        /// Plain words for the state, and the dot it gets.
        var look: (ring: SelectionRing.Kind?, text: String) {
            if endedAt != nil { return (nil, "Ended") }
            return switch state {
            case "working", "running", "starting", "busy": (.working, "Working")
            case "blocked": (.waiting, "Waiting for you")
            case "idle": (.idle, "Ready")
            case "done", "completed": (nil, "Done")
            case "stopped": (nil, "Stopped")
            case "failed", "crashed", "error": (.error, "Failed")
            case nil: (nil, "")
            case let other?: (.idle, other.prefix(1).uppercased() + other.dropFirst().replacingOccurrences(of: "_", with: " "))
            }
        }
    }

    /// Tolerant: unknown fields are ignored, unknown values kept as text, missing ones left nil. An entry with
    /// nothing to call it by (no id, session id or pid) is dropped.
    static func parse(_ data: Data) -> [Agent] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return list.compactMap { item in
            guard let obj = item as? [String: Any] else { return nil }
            func text(_ key: String) -> String? {
                switch obj[key] {
                case let value as String: value
                case let value as NSNumber: value.stringValue
                default: nil
                }
            }
            let pid = (obj["pid"] as? NSNumber)?.int32Value
            guard let id = text("id") ?? text("sessionId") ?? pid.map(String.init) else { return nil }
            return Agent(id: id, kind: text("kind") ?? "unknown", sessionId: text("sessionId"), cwd: text("cwd"),
                         name: text("name"), state: text("state") ?? text("status"), pid: pid,
                         startedAt: (obj["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
        }
    }

    /// Everything but meepo's own sessions: its session ids, or run from inside meepo.
    static func others(_ agents: [Agent], ownSessionIds: Set<String>) -> [Agent] {
        agents.filter { !$0.isInsideMeepo && !ownSessionIds.contains($0.sessionId ?? "") }
    }

    static let endedKept: TimeInterval = 24 * 3600

    /// The new list, plus interactive sessions seen before and gone now (their window ended them), kept up to
    /// a day so Continue here has something to act on. One that shows up again is live again.
    static func merge(_ current: [Agent], into previous: [Agent], now: Date = .now) -> [Agent] {
        let live = Set(current.compactMap(\.sessionId))
        let ended = previous.compactMap { agent -> Agent? in
            guard agent.isInteractive, let sessionId = agent.sessionId, !live.contains(sessionId) else { return nil }
            var agent = agent
            if agent.endedAt == nil { agent.endedAt = now }
            return now.timeIntervalSince(agent.endedAt!) < endedKept ? agent : nil
        }
        return current + ended
    }

    /// The app a process runs in, from its parents' executables (nearest first): the outermost `.app` of the
    /// first one inside an app, named as people say it.
    static func hostApp(ancestorPaths: [String]) -> String? {
        for path in ancestorPaths {
            guard let bundle = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) else { continue }
            let name = String(bundle.dropLast(4))
            if name.hasPrefix("Visual Studio Code") || name == "Code" { return "VS Code" }
            if name.hasPrefix("iTerm") { return "iTerm" }
            return name
        }
        return nil
    }

    /// Parent pids and their executables, nearest first, up to launchd.
    static func ancestors(of pid: pid_t) -> [(pid: pid_t, path: String?)] {
        var result: [(pid_t, String?)] = []
        var current = pid
        while result.count < 32, let parent = parent(of: current), parent > 1 {
            result.append((parent, path(of: parent)))
            current = parent
        }
        return result
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `claude agents --json`, each interactive one with its host app and whether meepo runs it.
    /// Nil when claude couldn't be asked (an older claude without `agents`). Blocking; call off the main thread.
    static func list(login: ClaudeLauncher.LoginEnvironment, meepo: pid_t = getpid()) -> [Agent]? {
        let (ok, output) = run(["agents", "--json"], login: login)
        guard ok else { return nil }
        return parse(Data(output.utf8)).map { agent in
            guard let pid = agent.pid else { return agent }
            var agent = agent
            let chain = ancestors(of: pid)
            agent.isInsideMeepo = chain.contains { $0.pid == meepo }
            agent.host = hostApp(ancestorPaths: chain.compactMap(\.path))
            return agent
        }
    }

    /// `claude <arguments>` with the login shell's environment; stdout and stderr together. Blocking, at most
    /// `timeout`: a hung claude is killed and counts as failed.
    static func run(_ arguments: [String], login: ClaudeLauncher.LoginEnvironment,
                    timeout: TimeInterval = 5) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: login.claudePath)
        process.arguments = arguments
        process.environment = login.environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, error.localizedDescription) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    /// Terminal output as plain text: colors, cursor moves and titles (ANSI escapes) out.
    static func plainText(_ output: String) -> String {
        output
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[()*+].", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[@-_]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }
}
