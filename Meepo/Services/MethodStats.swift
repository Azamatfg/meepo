import Foundation

/// Meepo's method, measured: is work getting better, by numbers rather than by feel (METR: people felt 20% faster
/// while taking 19% longer). The last two weeks next to the two before.
enum MethodStats {
    struct Window: Equatable {
        /// What you typed (not slash commands) per push; fewer = fewer corrections. Nil without a push.
        var requestsPerPush: Double?
        var pushes = 0
        /// Turns that changed files and ended with the project's check passing, of the turns that changed files in
        /// sessions with a check. Nil without such turns.
        var checkedShare: Double?
    }

    static let days = 14

    /// `entries`: ~/.claude/history.jsonl; `pushes`: when each push went out; both for the folders in `projects`
    /// (a worktree counts for its project).
    static func window(from start: Date, to end: Date, entries: [Noticing.Entry], pushes: [Date],
                       projects: [String], events: [HookEvent]) -> Window {
        let typed = entries.filter { entry in
            entry.date >= start && entry.date < end && !entry.display.hasPrefix("/")
                && projects.contains { entry.project == $0 || entry.project?.hasPrefix($0 + "/") == true }
        }.count
        let sent = pushes.filter { $0 >= start && $0 < end }.count
        let checked = Set(events.filter { $0.name == "Verify" }.map(\.sessionId)) // a project without a check isn't failing it
        let turns = Runs.from(events.filter { $0.createdAt >= start && $0.createdAt < end })
            .filter { $0.isDone && !$0.files.isEmpty && checked.contains($0.sessionId) }
        return Window(requestsPerPush: sent == 0 ? nil : Double(typed) / Double(sent), pushes: sent,
                      checkedShare: turns.isEmpty ? nil : Double(turns.filter { $0.check?.passed == true }.count) / Double(turns.count))
    }

    /// When each push from this repo went out: "update by push" in the reflogs of its remote branches.
    static func pushDates(in path: String) -> [Date] {
        guard let logs = GitService.output(["rev-parse", "--git-path", "logs/refs/remotes"], in: path) else { return [] }
        let dir = logs.hasPrefix("/") ? URL(filePath: logs) : URL(filePath: path).appending(path: logs)
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { $0 as? URL }.flatMap { file in
            Work.parseReflog((try? String(contentsOf: file, encoding: .utf8)) ?? "").filter { $0.subject == "update by push" }.map(\.date)
        }
    }
}
