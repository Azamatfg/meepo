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
    static func ensureWorktreesIgnored(in path: String) {
        guard !succeeds(["check-ignore", "-q", ".claude/worktrees/x"], in: path),
              let exclude = run(["rev-parse", "--git-path", "info/exclude"], in: path) else { return }
        let url = exclude.hasPrefix("/") ? URL(filePath: exclude) : URL(filePath: path).appending(path: exclude)
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let line = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + ".claude/worktrees/\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((current + line).utf8).write(to: url)
    }

    /// `git worktree remove` refuses a dirty worktree; `branch -d` refuses an unmerged branch. Nil = done.
    static func removeWorktree(at worktree: String, branch: String, in path: String) -> String? {
        guard succeeds(["worktree", "remove", worktree], in: path) else {
            return "Worktree has uncommitted changes or is in use: \(worktree)"
        }
        _ = succeeds(["branch", "-d", branch], in: path)
        return nil
    }

    static func hasUncommittedChanges(in path: String) -> Bool {
        run(["status", "--porcelain"], in: path) != nil
    }

    private static func succeeds(_ args: [String], in path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", path] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Runs git and returns trimmed stdout, or nil on failure or empty output.
    private static func run(_ args: [String], in path: String) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", path] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
