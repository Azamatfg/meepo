import Foundation

enum GitError: LocalizedError, Equatable {
    case notARepository(String)

    var errorDescription: String? {
        switch self {
        case .notARepository(let path): "Not a git repository: \(path)"
        }
    }
}

enum GitService {
    /// Top-level folder of the repository containing `path` (so picking a subfolder still adds the repo).
    static func repositoryRoot(of path: String) throws -> String {
        guard let root = run(["rev-parse", "--show-toplevel"], in: path) else {
            throw GitError.notARepository(path)
        }
        return root
    }

    static func remoteURL(in path: String) -> String? {
        run(["remote", "get-url", "origin"], in: path)
    }

    static func currentBranch(in path: String) -> String? {
        run(["branch", "--show-current"], in: path)
    }

    static func headCommit(in path: String) -> String? {
        run(["rev-parse", "HEAD"], in: path)
    }

    /// The feature branch moved past where it started and all of it is in the main checkout's HEAD.
    static func isMerged(branch: String, startedAt base: String, in path: String) -> Bool {
        guard let tip = run(["rev-parse", "--verify", "--quiet", branch], in: path), tip != base else { return false }
        return succeeds(["merge-base", "--is-ancestor", branch, "HEAD"], in: path)
    }

    /// `.claude/worktrees/` must not show up as untracked; uses the local, uncommitted exclude file.
    static func ensureWorktreesIgnored(in path: String, backups: URL) {
        ignoreLocally(".claude/worktrees/", in: path, backups: backups)
    }

    /// Adds `pattern` to the repo's own exclude file (never committed; worktrees find theirs), unless git
    /// already ignores it. Backed up and logged in Tools → Changes.
    static func ignoreLocally(_ pattern: String, in path: String, backups: URL) {
        guard !succeeds(["check-ignore", "-q", pattern.hasSuffix("/") ? pattern + "x" : pattern], in: path),
              let exclude = run(["rev-parse", "--git-path", "info/exclude"], in: path) else { return }
        let url = exclude.hasPrefix("/") ? URL(filePath: exclude) : URL(filePath: path).appending(path: exclude)
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // check-ignore never reports a tracked file, so it can't tell the line is already there.
        guard !current.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == pattern })
        else { return }
        let line = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + pattern + "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = try? ChangeLog.backup(url, folder: "git-exclude", backups: backups)
        guard (try? Data((current + line).utf8).write(to: url)) != nil else { return }
        ChangeLog.record("Ignore \(pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/")))", file: url, backup: backup, backups: backups)
    }

    /// `git worktree remove` refuses a dirty worktree; `branch -d` refuses an unmerged branch. Nil = done.
    static func removeWorktree(at worktree: String, branch: String, in path: String) -> String? {
        guard succeeds(["worktree", "remove", worktree], in: path) else {
            return "Worktree has uncommitted changes or is in use: \(worktree)"
        }
        _ = succeeds(["branch", "-d", branch], in: path)
        return nil
    }

    /// Claude Code locks the worktree it runs in and doesn't unlock it when killed, so git would refuse to
    /// remove it: releases such a lock once its claude is gone. The user's own locks and live claudes' stay.
    static func unlockIfClaudeGone(_ worktree: String, in path: String) {
        guard let file = run(["rev-parse", "--git-path", "locked"], in: worktree) else { return }
        let url = file.hasPrefix("/") ? URL(filePath: file) : URL(filePath: worktree).appending(path: file)
        guard let reason = try? String(contentsOf: url, encoding: .utf8), let pid = claudeLockPid(reason), pid > 1,
              kill(pid, 0) == -1, errno == ESRCH else { return }
        _ = succeeds(["worktree", "unlock", worktree], in: path)
    }

    /// "claude session login (pid 62446 start …)" → 62446 (the reason Claude Code 2.1.281 writes).
    static func claudeLockPid(_ reason: String) -> pid_t? {
        reason.firstMatch(of: #/^claude (?:agent|session) .+ \(pid (\d+)/#).flatMap { pid_t($0.1) }
    }

    /// "abc1234 subject" of today's commits on all local branches (worktrees included), newest first.
    static func commits(since start: Date, in path: String, limit: Int = 30) -> [String] {
        let since = ISO8601DateFormatter().string(from: start)
        return run(["log", "--branches", "--no-merges", "--since=\(since)", "--format=%h %s", "-n", String(limit)], in: path)?
            .split(separator: "\n").map(String.init) ?? []
    }

    /// The file is committed or staged in the repository (not just present on disk).
    static func isRepository(_ path: String) -> Bool {
        succeeds(["rev-parse", "--is-inside-work-tree"], in: path)
    }

    static func isTracked(_ file: String, in path: String) -> Bool {
        succeeds(["ls-files", "--error-unmatch", "--", file], in: path)
    }

    /// Raw stdout (file contents may be binary); nil on failure.
    static func data(_ args: [String], in path: String) -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments(args, in: path)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// Stdout even when git exits non-zero (`diff --no-index` exits 1 when files differ).
    static func outputAllowingFailure(_ args: [String], in path: String) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments(args, in: path)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs git; nil on success, otherwise git's own message (for push/pull errors the user should read).
    static func runReportingError(_ args: [String], in path: String) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments(args, in: path)
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        do { try process.run() } catch { return error.localizedDescription }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        guard process.terminationStatus != 0 else { return nil }
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git \(args.first ?? "") failed" : message
    }

    /// Trimmed stdout of any git command; nil on failure or empty output.
    static func output(_ args: [String], in path: String) -> String? {
        run(args, in: path)
    }

    /// Polled every 10 s in the background; no optional locks, so it never takes index.lock while Claude commits.
    static func hasUncommittedChanges(in path: String) -> Bool {
        run(["--no-optional-locks", "status", "--porcelain"], in: path) != nil
    }

    private static func succeeds(_ args: [String], in path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments(args, in: path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitForExit()
        return process.terminationStatus == 0
    }

    /// Every git call: `core.quotePath=false` keeps non-ASCII paths readable ("отчёт.md", not "\320\276…"),
    /// as Claude Code runs git — so such files compare, count and color like any other.
    private static func arguments(_ args: [String], in path: String) -> [String] {
        ["-c", "core.quotePath=false", "-C", path] + args
    }

    /// Runs git and returns trimmed stdout, or nil on failure or empty output.
    private static func run(_ args: [String], in path: String) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments(args, in: path)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
