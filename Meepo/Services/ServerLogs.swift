import Foundation

/// Hosts from ~/.ssh/config (SPEC module 10). Only `Host` names matter: ssh itself resolves the rest.
enum SSHConfig {
    /// Hosts that serve git, never logs.
    static let gitHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org", "ssh.github.com", "altssh.gitlab.com"]

    static var userConfig: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config") }

    /// Every concrete `Host` name, in file order: patterns (`*`, `?`, `!`) are skipped, and so are aliases of git
    /// hosts (`Host github-work` with `HostName github.com`). `Include` and `Match` are not followed.
    static func hosts(_ text: String) -> [String] {
        var blocks: [(names: [String], hostName: String?)] = []
        var inHostBlock = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // "Keyword value" or "Keyword=value".
            guard let split = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { continue }
            let keyword = line[..<split].lowercased()
            let value = line[line.index(after: split)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
            switch keyword {
            case "host":
                let names = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }.filter { !$0.isEmpty }
                blocks.append((names, nil))
                inHostBlock = true
            case "match":
                inHostBlock = false
            case "hostname" where inHostBlock && blocks[blocks.count - 1].hostName == nil: // ssh: the first one wins
                blocks[blocks.count - 1].hostName = value.lowercased()
            default:
                continue
            }
        }
        var result: [String] = []
        for block in blocks where !gitHosts.contains(block.hostName ?? "") {
            for name in block.names where !name.contains(where: { "*?!".contains($0) })
                && !gitHosts.contains(name.lowercased()) && !result.contains(name) && ServerLogs.isValidHost(name) {
                result.append(name)
            }
        }
        return result
    }
}

/// Server logs over ssh — read-only templates only (SPEC module 10, §8). Nothing but a template ever runs on a
/// server: names are checked strictly and quoted, and the host can't smuggle in an ssh option.
enum ServerLogs {
    static let ssh = "/usr/bin/ssh"
    static let lines = 200
    static let timeout: TimeInterval = 15
    /// Lists the server's running containers.
    static let listContainers = "docker ps --format '{{.Names}}'"

    struct RunResult: Sendable, Equatable {
        var status: Int32
        var output: String
        var timedOut = false
    }

    /// (executable, arguments, timeout) → result. Blocking; injected in tests so no real ssh ever runs.
    typealias Runner = @Sendable (String, [String], TimeInterval) -> RunResult

    /// An ssh alias, user@host, or ssh://[user@]host[:port] (a port needs ssh's URI form); never starts with "-"
    /// (ssh would read it as an option).
    static func isValidHost(_ host: String) -> Bool {
        host.wholeMatch(of: /([A-Za-z0-9_][A-Za-z0-9._-]*@)?[A-Za-z0-9_][A-Za-z0-9._-]{0,252}/) != nil
            || host.wholeMatch(of: /ssh:\/\/([A-Za-z0-9_][A-Za-z0-9._-]*@)?[A-Za-z0-9_][A-Za-z0-9._-]{0,252}(:[0-9]{1,5})?/) != nil
    }

    /// What the user pastes, the way they type it in a terminal — `ssh root@1.2.3.4`, `ssh -p 2222 -l deploy box`,
    /// or just the host — as the host meepo keeps. nil for anything else (-i, -J…: those belong in ~/.ssh/config).
    static func destination(from typed: String) -> String? {
        var words = typed.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first == "ssh" { words.removeFirst() }
        var port: String?, user: String?, host: String?
        while !words.isEmpty {
            let word = words.removeFirst()
            if word == "-p" || word == "-l" {
                guard !words.isEmpty else { return nil }
                if word == "-p" { port = words.removeFirst() } else { user = words.removeFirst() }
            } else if word.hasPrefix("-p"), word.count > 2 {
                port = String(word.dropFirst(2))
            } else if word.hasPrefix("-") || host != nil {
                return nil
            } else {
                host = word
            }
        }
        guard var host else { return nil }
        if let user, !host.contains("@") { host = "\(user)@\(host)" }
        let result = port.map { "ssh://\(host):\($0)" } ?? host
        return isValidHost(result) ? result : nil
    }

    static func isValid(_ source: LogSource) -> Bool {
        switch source.kind {
        case .journal: source.name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9@._:-]{0,199}/) != nil
        case .docker: source.name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,199}/) != nil
        case .file: source.name.wholeMatch(of: /\/[A-Za-z0-9._\/@+-]{1,500}/) != nil
        }
    }

    /// What runs on the server; nil when the name isn't one the template accepts.
    static func command(for source: LogSource) -> String? {
        guard isValid(source) else { return nil }
        let name = "'\(source.name)'" // valid names hold no quote, so this is the whole word, taken literally
        return switch source.kind {
        case .journal: "journalctl -u \(name) -n \(lines) --no-pager"
        case .docker: "docker logs --tail \(lines) \(name)"
        case .file: "tail -n \(lines) \(name)"
        }
    }

    /// ssh without prompts: keys and agent only, a dead host fails fast; its warnings (a new host key) stay out of the log.
    static func sshArguments(host: String, command: String) -> [String]? {
        guard isValidHost(host) else { return nil }
        return ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", host, command]
    }

    /// An interactive shell on the server, in a meepo terminal: prompts (a password, a new host key) are the user's to answer.
    static func shellArguments(host: String) -> [String]? {
        guard isValidHost(host) else { return nil }
        return ["-o", "ConnectTimeout=10", host]
    }

    /// Logs from one source, trimmed; `error` in plain words when ssh or the command failed.
    struct Fetched: Sendable, Equatable {
        let host: String
        let command: String
        var log = ""
        var error: String?
    }

    /// Blocking; call off the main thread.
    static func fetch(_ source: LogSource, from host: String, runner: Runner) -> Fetched {
        guard let command = command(for: source), let args = sshArguments(host: host, command: command) else {
            return Fetched(host: host, command: source.name, error: "“\(source.name)” isn't a name meepo can pass safely.")
        }
        let result = runner(ssh, args, timeout)
        var fetched = Fetched(host: host, command: command, log: trim(result.output))
        if let problem = problem(result, host: host) { fetched.error = problem }
        return fetched
    }

    /// Container names on the server, or why not.
    static func containers(on host: String, runner: Runner) -> Result<[String], ListError> {
        guard let args = sshArguments(host: host, command: listContainers) else { return .failure(ListError(text: "Not a host name.")) }
        let result = runner(ssh, args, timeout)
        if let problem = problem(result, host: host) { return .failure(ListError(text: problem)) }
        return .success(result.output.split(whereSeparator: \.isNewline).map(String.init)
            .filter { isValid(LogSource(kind: .docker, name: $0)) })
    }

    struct ListError: Error, Equatable { let text: String }

    private static func problem(_ result: RunResult, host: String) -> String? {
        if result.timedOut { return "\(host) didn't answer in \(Int(timeout)) s." }
        guard result.status != 0 else { return nil }
        let last = trim(result.output).split(separator: "\n").last.map(String.init) ?? ""
        if result.status == 255 {
            return "ssh couldn't log in to \(host)\(last.isEmpty ? "" : ": \(last)"). meepo never asks for passwords — `ssh \(host)` has to work in Terminal without one (a key in ssh-agent)."
        }
        return "The server answered with an error\(last.isEmpty ? "" : ": \(last)")."
    }

    /// The last `lines` lines, at most `limit` bytes. Colors and every control character but newline and tab go:
    /// an escape or a carriage return in a log would end the paste and type into Claude as keys.
    static func trim(_ raw: String, lines: Int = lines, limit: Int = 16_000) -> String {
        let plain = ClaudeAgents.plainText(raw)
        let scalars = plain.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
        var all = String(String.UnicodeScalarView(scalars)).split(separator: "\n", omittingEmptySubsequences: false)
        while all.last?.isEmpty == true { all.removeLast() }
        var kept = Array(all.suffix(lines))
        var cut = kept.count < all.count
        while kept.count > 1, kept.reduce(0, { $0 + $1.utf8.count + 1 }) > limit {
            kept.removeFirst()
            cut = true
        }
        var text = kept.joined(separator: "\n")
        if text.utf8.count > limit { text = String(decoding: Array(text.utf8.suffix(limit)), as: UTF8.self) } // one huge line
        return cut ? "… (earlier lines cut)\n" + text : text
    }

    /// One source's logs as a block for Claude.
    static func block(_ fetched: Fetched) -> String {
        "Logs from \(fetched.host) — `\(fetched.command)`:\n```\n\(fetched.log)\n```"
    }

    /// Pasted into a session like a paste from the clipboard: Claude Code shows it folded, and nothing is sent
    /// until the user presses Enter.
    static func paste(_ fetched: [Fetched]) -> String {
        "\u{1B}[200~" + fetched.map(block).joined(separator: "\n\n") + "\n\u{1B}[201~"
    }

    /// A new session's first message.
    static func investigatePrompt(_ fetched: [Fetched], why: String? = nil) -> String {
        let hosts = Array(NSOrderedSet(array: fetched.map(\.host))).compactMap { $0 as? String }.joined(separator: ", ")
        return (why.map { "\($0)\n" } ?? "")
            + "Investigate these logs from \(hosts): what went wrong and why? Read only — don't change anything on the server.\n\n"
            + fetched.map(block).joined(separator: "\n\n")
    }

    /// The real runner: ssh's output and errors together, killed after `timeout`.
    static func runProcess(_ executable: String, _ args: [String], _ timeout: TimeInterval) -> RunResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return RunResult(status: -1, output: error.localizedDescription) }
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        let killed = process.terminationReason == .uncaughtSignal && Date().timeIntervalSince(started) >= timeout - 0.5
        return RunResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self), timedOut: killed)
    }
}
