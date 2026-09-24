import Foundation

/// Git for the session inspector: what the session changed (committed or not), ahead/behind its upstream,
/// and PULL / PUSH on the user's click — never forced.
enum GitPanel {
    struct FileChange: Identifiable, Equatable {
        /// Porcelain code: M modified, A added, D deleted, R renamed, ? untracked.
        let status: String
        let path: String
        var added: Int?
        var removed: Int?
        /// Still only in the working tree (the agent hasn't committed it).
        var isUncommitted = false
        /// A renamed file's path before the rename.
        var oldPath: String?
        var id: String { path }
    }

    struct Snapshot: Equatable {
        var branch = ""
        var upstream: String?
        var ahead = 0
        var behind = 0
        var changes: [FileChange] = []
    }

    /// Blocking; call off the main thread.
    static func snapshot(in path: String) -> Snapshot {
        var snapshot = parseStatus(GitService.output(["status", "--porcelain=v1", "-b", "-uall"], in: path) ?? "")
        let counts = parseNumstat(GitService.output(["diff", "--numstat", "HEAD"], in: path) ?? "")
        for index in snapshot.changes.indices {
            if let (added, removed) = counts[snapshot.changes[index].path] {
                snapshot.changes[index].added = added
                snapshot.changes[index].removed = removed
            }
        }
        return snapshot
    }

    /// `## main...origin/main [ahead 5, behind 1]` then ` M path`, `?? path`, `R  old -> new`.
    static func parseStatus(_ text: String) -> Snapshot {
        var snapshot = Snapshot()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("## ") {
                let header = line.dropFirst(3)
                let names = header.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                let parts = names.components(separatedBy: "...")
                snapshot.branch = parts[0].replacingOccurrences(of: "No commits yet on ", with: "")
                snapshot.upstream = parts.count > 1 ? parts[1] : nil
                if let ahead = header.firstMatch(of: /ahead (\d+)/) { snapshot.ahead = Int(ahead.1) ?? 0 }
                if let behind = header.firstMatch(of: /behind (\d+)/) { snapshot.behind = Int(behind.1) ?? 0 }
                continue
            }
            guard line.count > 3 else { continue }
            let code = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            let status = code == "??" ? "?" : String(code.trimmingCharacters(in: .whitespaces).prefix(1))
            snapshot.changes.append(FileChange(status: status, path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))))
        }
        return snapshot
    }

    /// `added<TAB>removed<TAB>path`; binary files show "-".
    static func parseNumstat(_ text: String) -> [String: (Int, Int)] {
        var result: [String: (Int, Int)] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { continue }
            result[String(fields[2])] = (Int(fields[0]) ?? 0, Int(fields[1]) ?? 0)
        }
        return result
    }

    /// The folder as VS Code's Source Control shows it (user decision 2026-09-24): CHANGES not committed yet,
    /// INCOMING commits teammates pushed that aren't here, OUTGOING commits here that aren't pushed.
    struct SourceControl: Equatable {
        /// A plain folder project (no git): the inspector offers git init instead of the groups.
        var isRepository = true
        var branch = ""
        var upstream: String?
        var changes: [FileChange] = []
        var incoming = Group()
        var outgoing = Group()
        var ahead: Int { outgoing.commits.count }
        var behind: Int { incoming.commits.count }
    }

    /// Commits on one side of the upstream and the files they change together.
    struct Group: Equatable {
        var commits: [CommitLine] = []
        var files: [FileChange] = []
        /// Where the compare view's left side comes from (the common ancestor) and its right side.
        var from: String?
        var to: String?
    }

    struct CommitLine: Equatable, Identifiable {
        let sha: String
        let author: String
        let subject: String
        let when: String
        var id: String { sha }
    }

    /// Blocking; call off the main thread.
    static func sourceControl(in path: String) -> SourceControl {
        guard GitService.output(["rev-parse", "--is-inside-work-tree"], in: path) == "true" else {
            return SourceControl(isRepository: false)
        }
        let status = parseStatus(GitService.output(["status", "--porcelain=v1", "-b", "-uall"], in: path) ?? "")
        var result = SourceControl(branch: status.branch, upstream: status.upstream)
        let counts = parseNumstat(GitService.output(["diff", "--numstat", "HEAD"], in: path) ?? "")
        result.changes = status.changes.map { change in
            var change = change
            change.added = counts[change.path]?.0
            change.removed = counts[change.path]?.1
            change.isUncommitted = true
            return change
        }
        guard status.upstream != nil, let base = GitService.output(["merge-base", "HEAD", "@{u}"], in: path) else { return result }
        result.incoming = group(from: base, to: "@{u}", range: "HEAD..@{u}", in: path)
        result.outgoing = group(from: base, to: "HEAD", range: "@{u}..HEAD", in: path)
        return result
    }

    private static func group(from base: String, to tip: String, range: String, in path: String) -> Group {
        let log = GitService.output(["log", "--format=%h%x1f%an%x1f%s%x1f%cr", "-n", "30", range], in: path) ?? ""
        let commits = log.split(separator: "\n").compactMap { line -> CommitLine? in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            return f.count == 4 ? CommitLine(sha: f[0], author: f[1], subject: f[2], when: f[3]) : nil
        }
        guard !commits.isEmpty else { return Group() }
        return Group(commits: commits, files: files(between: base, and: tip, in: path), from: base, to: tip)
    }

    /// Files that differ between two commits, with +/− (renames keep their old path for the left side).
    static func files(between old: String, and new: String, in path: String) -> [FileChange] {
        let counts = parseNumstat(GitService.output(["diff", "--numstat", old, new], in: path) ?? "")
        return (GitService.output(["diff", "--name-status", old, new], in: path) ?? "").split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count >= 2, let file = fields.last else { return nil }
            return FileChange(status: String(fields[0].prefix(1)), path: file, added: counts[file]?.0, removed: counts[file]?.1,
                              oldPath: fields.count == 3 ? fields[1] : nil)
        }
    }

    /// Both sides of a file for the compare view: `old` at a commit, `new` at a commit or (nil) on disk.
    static func versions(of change: FileChange, old: String?, new: String?, in path: String) -> (old: Data?, new: Data?) {
        let before = ["?", "A"].contains(change.status) ? nil
            : GitService.data(["show", "\(old ?? "HEAD"):\(change.oldPath ?? change.path)"], in: path)
        let after: Data? = change.status == "D" ? nil
            : new.map { GitService.data(["show", "\($0):\(change.path)"], in: path) }
                ?? (try? Data(contentsOf: URL(filePath: path).appending(path: change.path)))
        return (before, after)
    }

    /// For EXPLAIN: the changes between two points (`to` nil = the files on disk).
    static func fullDiff(from: String, to: String?, in path: String) -> String {
        GitService.output(["diff", from] + (to.map { [$0] } ?? []), in: path) ?? ""
    }

    /// No force ever; a branch without an upstream gets one on origin.
    static func push(_ snapshot: Snapshot, in path: String) -> String? {
        let args = snapshot.upstream == nil ? ["push", "-u", "origin", snapshot.branch] : ["push"]
        return GitService.runReportingError(args, in: path)
    }

    /// Auto-sync: the user's unpushed commits go on top of the teammates' ones. Never a stash (the user's rule:
    /// the stash is shared by all worktrees), so a dirty tree is refused by git; a conflict is aborted at once,
    /// leaving the folder exactly as it was. nil = done, otherwise git's message.
    static func pullRebase(in path: String) -> String? {
        guard let error = GitService.runReportingError(["pull", "--rebase", "--no-autostash"], in: path) else { return nil }
        _ = GitService.runReportingError(["rebase", "--abort"], in: path)
        return error
    }

    /// Teammates' commits on the upstream that this folder doesn't have yet: "abc1234 Rustem: fix x", and the files.
    static func incoming(in path: String) -> (commits: [String], files: [String]) {
        let commits = (GitService.output(["log", "--format=%h %an: %s", "-n", "30", "HEAD..@{u}"], in: path) ?? "")
            .split(separator: "\n").map(String.init)
        let files = (GitService.output(["diff", "--name-only", "HEAD...@{u}"], in: path) ?? "")
            .split(separator: "\n").map(String.init)
        return (commits, files)
    }

    /// What the agent is told on its next prompt when teammates pushed (SPEC: auto-sync keeps its memory fresh).
    static func teammateNote(commits: [String], files: [String], upstream: String, pulled: Bool) -> String {
        var lines = ["[Meepo] Teammates pushed \(commits.count) new commit\(commits.count == 1 ? "" : "s") to \(upstream)"
            + (pulled ? ", already pulled into this folder (git pull --rebase):"
                      : ". Not pulled yet: this folder has uncommitted changes. Commit your work, then run git pull --rebase:")]
        lines += commits.prefix(15).map { "- \($0)" }
        if !files.isEmpty {
            lines.append("Files they changed: " + files.prefix(30).joined(separator: ", ") + (files.count > 30 ? ", …" : ""))
            lines.append("Re-read these files before editing them; don't undo their changes.")
        }
        return lines.joined(separator: "\n")
    }

    /// Fast-forward only: never a merge commit or a conflict in the user's tree.
    static func pull(in path: String) -> String? {
        GitService.runReportingError(["pull", "--ff-only"], in: path)
    }

    static func fetch(in path: String) {
        _ = GitService.runReportingError(["fetch", "--quiet"], in: path)
    }

    static func isMainBranch(_ branch: String) -> Bool { ["main", "master"].contains(branch) }
}

extension GitPanel {
    /// For EXPLAIN: what the changes do, in plain words, for someone who doesn't read diffs yet.
    /// `whose`: "the user's uncommitted", "teammates' incoming"… — so the reader knows whose work it is.
    static func explainPrompt(diff: String, newFiles: [String], whose: String = "these uncommitted", language: String) -> String {
        var parts = ["""
            Explain \(whose) code changes to someone who is learning to build software with an AI agent. \
            In \(language). Start with one sentence on what changed overall, then a short list: what each change \
            does and why it matters, in plain words. Mention anything risky (deleted code, config, secrets, \
            migrations). No code blocks, under 200 words.
            """]
        if !newFiles.isEmpty { parts.append("<new_files>\n" + newFiles.joined(separator: "\n") + "\n</new_files>") }
        parts.append("<diff>\n\(diff.prefix(30_000))\n</diff>")
        return parts.joined(separator: "\n\n")
    }

    /// The user's first macOS language by name ("Russian"), so the explanation reads in their language.
    static var userLanguage: String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}
