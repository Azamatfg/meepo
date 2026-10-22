import Foundation

/// Replay (evals from sessions, github.com/ibragim-bad/evals-from-sessions): a task the user already did — a
/// commit and the requests behind it — done again by Claude on another setup, in a copy of the code before it, then
/// graded by the tests that commit added. The agent never sees those tests: they're put in only after it's done.
enum Replay {
    /// A commit worth replaying: one parent, small, and it changed tests as well as code.
    struct Candidate: Hashable, Identifiable {
        let sha: String
        let subject: String
        let date: Date
        let tests: [String]
        let lines: Int
        var id: String { sha }
    }

    /// Big commits are waves of several tasks; an instruction for one of them can't be fair.
    static let maxLines = 150

    /// Newest first, from the last `scan` commits of `repo`.
    static func candidates(in repo: String, scan: Int = 300) -> [Candidate] {
        let log = GitService.output(["log", "--no-merges", "-n", "\(scan)", "--format=%x1e%H%x1f%P%x1f%cI%x1f%s", "--numstat"],
                                    in: repo) ?? ""
        return log.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            let head = lines.first?.split(separator: "\u{1f}", omittingEmptySubsequences: false) ?? []
            guard head.count == 4, head[1].split(separator: " ").count == 1,
                  let date = try? Date(String(head[2]), strategy: .iso8601) else { return nil }
            var tests: [String] = [], changed = 0, code = false
            for line in lines.dropFirst() {
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3 else { continue }
                changed += (Int(parts[0]) ?? 0) + (Int(parts[1]) ?? 0)
                if isTest(String(parts[2])) { tests.append(String(parts[2])) } else { code = true }
            }
            guard !tests.isEmpty, code, changed <= maxLines else { return nil }
            return Candidate(sha: String(head[0]), subject: String(head[3]), date: date, tests: tests, lines: changed)
        }
    }

    /// Test files by the usual names: a Tests/test/spec folder, `*.test.ts`, `foo_test.go`, `test_foo.py`, `FooTests.swift`.
    static func isTest(_ path: String) -> Bool {
        path.range(of: #"(^|/)([Tt]ests?|__tests__|[Ss]pecs?|\w*Tests)/|[._]test\.|[._]spec\.|_test\.\w+$|(^|/)test_[^/]*$|\wTests?\.swift$"#,
                   options: .regularExpression) != nil
    }

    /// The code at `sha` as a fresh repo of one commit: no history to read the answer from, no remote to push to.
    static func snapshot(_ sha: String, of repo: String, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try shell(#"git -C "$1" archive "$2" | tar -x -C "$3""#, repo, sha, folder.path)
        try shell(#"cd "$1" && git init -q && git add -A && git -c user.name=meepo -c user.email=replay@meepo commit -qm snapshot"#,
                  folder.path)
    }

    /// The commit's own versions of `tests` over whatever the agent left there. Ones the commit deleted are skipped.
    static func putTests(_ tests: [String], of sha: String, from repo: String, into folder: URL) throws {
        let kept = GitService.output(["ls-tree", "-r", "--name-only", sha, "--"] + tests, in: repo)?
            .split(separator: "\n").map(String.init) ?? []
        guard !kept.isEmpty else { return }
        try shell(#"repo="$1"; sha="$2"; dir="$3"; shift 3; git -C "$repo" archive "$sha" -- "$@" | tar -x -C "$dir""#,
                  [repo, sha, folder.path] + kept)
    }

    /// The check for a task: the project's own, narrowed for Xcode to the test classes the commit touched (a whole
    /// suite per run is minutes), building in the snapshot so the user's Debug build is left alone.
    static func checkCommand(base: String, tests: [String: String], hasProjectSpec: Bool) -> String {
        guard base.contains("xcodebuild"), base.contains(" test") else { return base }
        let only = tests.flatMap { path, text in
            text.matches(of: #/class\s+(\w+)\s*:\s*XCTestCase/#).map { "-only-testing:\(path.split(separator: "/")[0])/\($0.1)" }
        }.sorted()
        return (hasProjectSpec ? "xcodegen generate && " : "") + ([base, "-derivedDataPath .replay-build"] + only).joined(separator: " ")
    }

    /// What the agent is told to do; one setup of the comparison.
    struct Setup: Hashable, Codable {
        var model: String
        var effort: String
        var title: String { [model.isEmpty ? "default" : model, effort.isEmpty ? nil : effort].compactMap { $0 }.joined(separator: " · ") }
    }

    /// No one is there to answer a permission prompt; listed tools are allowed outright (auto mode would be reset
    /// to default under CLAUDE_CODE_SUBPROCESS_ENV_SCRUB, checked live on 2.1.302). So the bounds are hard ones:
    /// Bash in Claude Code's sandbox with no way out of it and no network (no ssh, gh or push), the real repo
    /// (`project`: where the answer is) and the key folders closed to Bash and the file tools alike, and none of
    /// the user's settings or hooks.
    static func agentArguments(_ setup: Setup, project: String) -> [String] {
        let hidden = [project] + secretFolders
        let settings: [String: Any] = [
            "sandbox": ["enabled": true, "allowUnsandboxedCommands": false, "failIfUnavailable": true,
                        "filesystem": ["denyRead": hidden]],
            "permissions": ["deny": hidden.flatMap { path in
                let rule = path.hasPrefix("~") ? path : "/" + path
                return ["Read", "Edit", "Write"].map { "\($0)(\(rule)/**)" }
            }],
        ]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: settings, options: .sortedKeys), as: UTF8.self)
        return ["-p", "--allowedTools", "Read Edit Write Glob Grep Bash", "--no-session-persistence", "--output-format", "json",
                "--setting-sources", "", "--settings", json]
            + (setup.model.isEmpty ? [] : ["--model", setup.model])
            + (setup.effort.isEmpty ? [] : ["--effort", setup.effort])
    }

    static let secretFolders = ["~/.ssh", "~/.aws", "~/.config/gh", "~/.gnupg", "~/.meepo", "~/.kube", "~/.docker"]

    /// The login environment without what reaches servers and accounts on the user's behalf.
    static func agentEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !["SSH_AUTH_SOCK", "GH_TOKEN", "GITHUB_TOKEN", "GITLAB_TOKEN", "NPM_TOKEN"].contains(key) && !key.hasPrefix("AWS_")
        }
    }

    /// An agent turn or a check longer than this is stuck (a watch-mode test, a loop): stopped, the run counts as broken.
    static let timeout: TimeInterval = 30 * 60

    /// What `claude -p --output-format json` reports about the run.
    struct Usage: Equatable {
        var cost: Double
        var seconds: Double
        var turns: Int
    }

    static func usage(fromJSON text: String) -> Usage? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let cost = object["total_cost_usd"] as? Double, let ms = object["duration_ms"] as? Double else { return nil }
        return Usage(cost: cost, seconds: ms / 1000, turns: object["num_turns"] as? Int ?? 0)
    }

    /// Runs the check in `folder` with the login shell's PATH; true when it exits 0.
    static func check(_ command: String, in folder: URL, environment: [String: String], timeout: TimeInterval = timeout) async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = environment
            process.currentDirectoryURL = folder
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
            process.waitForExit()
            return process.terminationStatus == 0 && process.terminationReason == .exit
        }.value
    }

    /// The instruction's first draft: what the user asked for while working on this commit, its message, and the
    /// names the hidden tests call — so the agent fails on the work, not on guessing a function's name.
    static func instructionPrompt(message: String, requests: [String], testDiff: String) -> String {
        """
        Write the task for a coding agent who will redo this change in the repository as it was before it. The \
        agent sees only your task, never the commit or its tests.

        - Say what to build or fix in the user's terms, as one request: what it must do, not how.
        - Name every type, function, signature and file the tests below use that doesn't exist yet, exactly, so \
        a correct solution can't fail on naming. Don't mention the tests or what they assert.
        - No preamble, no headings; plain text, at most 15 lines.

        <commit_message>
        \(message)
        </commit_message>

        <user_requests>
        \(requests.isEmpty ? "(none found)" : requests.map { "- \($0)" }.joined(separator: "\n"))
        </user_requests>

        <hidden_tests_diff>
        \(testDiff.prefix(20_000))
        </hidden_tests_diff>
        """
    }

    /// Prompts typed in `repo` (or its worktrees) between the commit before this one and this one, from
    /// ~/.claude/history.jsonl; slash commands and one-word answers ("да", "ok") aren't requests.
    static func requests(in repo: String, from start: Date, to end: Date, history: URL = Self.historyURL) -> [String] {
        guard let text = try? String(contentsOf: history, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let project = object["project"] as? String, project == repo || project.hasPrefix(repo + "/"),
                  let ms = object["timestamp"] as? Double, let prompt = object["display"] as? String else { return nil }
            let date = Date(timeIntervalSince1970: ms / 1000)
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard date > start, date <= end, !trimmed.hasPrefix("/"), trimmed.split(separator: " ").count > 2 else { return nil }
            return String(trimmed.prefix(1500))
        }
    }

    static let historyURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/history.jsonl")

    /// Every snapshot lives here while it runs and is removed after.
    static let workURL = FileManager.default.temporaryDirectory.appending(path: "meepo-replay")

    private static func shell(_ script: String, _ args: String...) throws {
        try shell(script, args)
    }

    private static func shell(_ script: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "sh"] + args
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try process.run()
        let message = err.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        guard process.terminationStatus == 0 else {
            throw ClaudeHeadless.Failure(errorDescription: String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
