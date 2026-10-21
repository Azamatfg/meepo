import Foundation
import os

/// Is development getting more effective with meepo: week by week, by numbers rather than by feel. Weeks before meepo
/// was installed are BEFORE; after that a week is MEEPO or TERMINAL by where most of its active hours went, so
/// working a week in a plain terminal is the whole experiment — nothing to switch.
enum Impact {
    /// Claude session ids meepo started, one per line: a session not here ran in a plain terminal.
    static let launchedFile = MeepoHome.url.appending(path: "launched")
    /// Longer than this you'd stepped away, not been kept waiting.
    static let maxPause: TimeInterval = 30 * 60
    static let reworkWindow: TimeInterval = 48 * 3600
    static let weekCount = 16

    enum Mode: String, CaseIterable { case before = "BEFORE", meepo = "MEEPO", terminal = "TERMINAL" }

    /// From after Claude finished a turn to the next thing you typed in that session.
    struct Pause: Equatable {
        let session: String
        let cwd: String
        /// When you answered.
        let date: Date
        let seconds: TimeInterval
    }

    struct Commit: Hashable {
        let date: Date
        let subject: String
        let files: [String]

        var isFix: Bool { subject.range(of: #"^(fix(\([^)]*\))?!?:|Revert ")"#, options: .regularExpression) != nil }
    }

    struct Totals: Equatable {
        var hours = 0
        var shipped = 0
        var rework = 0
        var ciRuns = 0
        var ciFailed = 0
        var waiting: TimeInterval = 0
        /// Days with a pause to count; nil waiting without them (older than the transcripts).
        var waitingDays = 0

        var shippedPerHour: Double? { hours == 0 ? nil : Double(shipped) / Double(hours) }
        var reworkShare: Double? { shipped == 0 ? nil : Double(rework) / Double(shipped) }
        var ciFailedShare: Double? { ciRuns == 0 ? nil : Double(ciFailed) / Double(ciRuns) }
        var waitingMinutesPerDay: Double? { waitingDays == 0 ? nil : waiting / 60 / Double(waitingDays) }

        static func + (a: Totals, b: Totals) -> Totals {
            Totals(hours: a.hours + b.hours, shipped: a.shipped + b.shipped, rework: a.rework + b.rework,
                   ciRuns: a.ciRuns + b.ciRuns, ciFailed: a.ciFailed + b.ciFailed,
                   waiting: a.waiting + b.waiting, waitingDays: a.waitingDays + b.waitingDays)
        }
    }

    struct Week: Identifiable, Equatable {
        let start: Date
        var mode: Mode
        var totals: Totals
        var id: Date { start }
    }

    /// Where a session's work counts: before meepo existed, before it kept a list (all meepo then), or by the list.
    struct Attribution {
        let installed: Date
        /// When the list began; nil = no list yet.
        let listedSince: Date?
        let launched: Set<String>

        func mode(session: String?, at date: Date) -> Mode {
            if date < installed { return .before }
            guard let listedSince, date >= listedSince else { return .meepo }
            return session.map(launched.contains) == true ? .meepo : .terminal
        }
    }

    // MARK: - Counting

    static func weekStart(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)!.start
    }

    /// The last `count` weeks, newest first, with any activity.
    static func weeks(now: Date, count: Int = weekCount, entries: [Noticing.Entry], commits: [Commit], ci: [CIRun],
                      pauses: [Pause], attribution: Attribution, calendar: Calendar = .current) -> [Week] {
        let first = calendar.date(byAdding: .weekOfYear, value: -(count - 1), to: weekStart(now, calendar: calendar))!
        let key = { (date: Date) in weekStart(date, calendar: calendar) }
        var totals: [Date: Totals] = [:]
        var hoursByMode: [Date: [Mode: Set<Date>]] = [:]
        for entry in entries where entry.date >= first {
            let hour = calendar.dateInterval(of: .hour, for: entry.date)!.start
            hoursByMode[key(entry.date), default: [:]][attribution.mode(session: entry.session, at: entry.date), default: []].insert(hour)
        }
        for (week, modes) in hoursByMode { totals[week, default: Totals()].hours = modes.values.reduce(into: Set<Date>()) { $0.formUnion($1) }.count }
        let fixes = Set(reworked(commits))
        for commit in commits where commit.date >= first {
            totals[key(commit.date), default: Totals()].shipped += 1
            if fixes.contains(commit) { totals[key(commit.date), default: Totals()].rework += 1 }
        }
        for run in ci where run.createdAt >= first && run.status == "completed" && ["success", "failure", "timed_out"].contains(run.conclusion) {
            totals[key(run.createdAt), default: Totals()].ciRuns += 1
            if run.failed { totals[key(run.createdAt), default: Totals()].ciFailed += 1 }
        }
        var days: [Date: Set<Date>] = [:]
        for pause in pauses where pause.date >= first {
            totals[key(pause.date), default: Totals()].waiting += pause.seconds
            days[key(pause.date), default: []].insert(calendar.startOfDay(for: pause.date))
        }
        for (week, set) in days { totals[week]?.waitingDays = set.count }
        return totals.keys.sorted(by: >).map { week in
            let modes = hoursByMode[week] ?? [:] // most hours wins; a tie goes to the earlier case
            let mode = modes.isEmpty ? attribution.mode(session: nil, at: week)
                : Mode.allCases.max { (modes[$0]?.count ?? 0) < (modes[$1]?.count ?? 0) }!
            return Week(start: week, mode: mode, totals: totals[week]!)
        }
    }

    /// Fixes and reverts that touch a file one of these commits changed in the 48 hours before: work done twice.
    static func reworked(_ commits: [Commit]) -> [Commit] {
        let sorted = commits.sorted { $0.date < $1.date }
        return sorted.enumerated().compactMap { index, commit in
            guard commit.isFix else { return nil }
            let files = Set(commit.files)
            let touched = sorted[..<index].contains { earlier in
                commit.date.timeIntervalSince(earlier.date) <= reworkWindow && !files.isDisjoint(with: earlier.files)
            }
            return touched ? commit : nil
        }
    }

    /// Pauses in one transcript: a turn that ended (`end_turn`) and the next prompt you typed — not a tool result,
    /// a background task's notice or Claude Code's own lines. Each is capped at `maxPause`. Transcripts run to
    /// gigabytes, mostly tool output: only lines that can matter are parsed.
    static func pauses(transcript data: Data) -> [Pause] {
        var ended: [String: Date] = [:]
        var pauses: [Pause] = []
        for line in candidateLines(data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["isSidechain"] as? Bool != true,
                  let session = object["sessionId"] as? String,
                  let date = (object["timestamp"] as? String).flatMap(isoDate) else { continue }
            let message = object["message"] as? [String: Any]
            if object["type"] as? String == "assistant" {
                if message?["stop_reason"] as? String == "end_turn" { ended[session] = date }
            } else if object["type"] as? String == "user", isTyped(object, message: message), let end = ended.removeValue(forKey: session) {
                let seconds = date.timeIntervalSince(end)
                if seconds > 0 {
                    pauses.append(Pause(session: session, cwd: object["cwd"] as? String ?? "", date: date, seconds: min(seconds, maxPause)))
                }
            }
        }
        return pauses
    }

    /// Lines with `"end_turn"`, or user lines without a tool result; memmem, since Data's own search is ~10× slower.
    private static func candidateLines(_ data: Data) -> [Data] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Data] in
            guard let base = raw.baseAddress else { return [] }
            let has = { (start: UnsafeRawPointer, length: Int, needle: StaticString) in
                memmem(start, length, needle.utf8Start, needle.utf8CodeUnitCount) != nil
            }
            var lines: [Data] = []
            var start = 0
            while start < raw.count {
                let rest = base + start
                let end = memchr(rest, 0x0A, raw.count - start).map { $0 - UnsafeMutableRawPointer(mutating: base) } ?? raw.count
                let length = end - start
                if has(rest, length, #""end_turn""#) || (has(rest, length, #""type":"user""#) && !has(rest, length, #""tool_result""#)) {
                    lines.append(Data(bytes: rest, count: length))
                }
                start = end + 1
            }
            return lines
        }
    }

    private static func isTyped(_ object: [String: Any], message: [String: Any]?) -> Bool {
        guard object["isMeta"] as? Bool != true, object["isCompactSummary"] as? Bool != true else { return false }
        let content = message?["content"]
        if let blocks = content as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return false }
        if let origin = object["origin"] as? [String: Any] { return origin["kind"] as? String == "human" } // newer claude says so
        let text = (content as? String) ?? (content as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
        return !text.hasPrefix("<") || text.hasPrefix("<command-") || text.hasPrefix("<bash-input")
    }

    private static func isoDate(_ string: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)) ?? (try? Date.ISO8601FormatStyle().parse(string))
    }

    /// `git log --format=%x1e%ct%x1f%s --name-only` → commits with the files they changed.
    static func parseLog(_ text: String) -> [Commit] {
        text.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let head = lines.first else { return nil }
            let parts = head.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let seconds = TimeInterval(parts[0]) else { return nil }
            return Commit(date: Date(timeIntervalSince1970: seconds), subject: String(parts[1]), files: lines.dropFirst().map(String.init))
        }
    }

    // MARK: - Reading (blocking; off the main thread)

    /// Adds the meepo sessions among `ids` to the list. The list's first write is when it began.
    static func remember(_ ids: Set<String>, file: URL = launchedFile) {
        guard !ids.isEmpty else { return }
        let known = Set(((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        let new = ids.subtracting(known)
        guard !new.isEmpty else { return }
        let text = new.sorted().map { $0 + "\n" }.joined()
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: file)
        }
    }

    static func attribution(home: URL = MeepoHome.url, file: URL = launchedFile) -> Attribution {
        let created = { (url: URL) in (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate }
        let launched = Set(((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        return Attribution(installed: created(home) ?? .distantPast, listedSince: created(file), launched: launched)
    }

    /// Your commits that reached the repo's default branch on its remote (merges left out), since `since`.
    static func commits(in path: String, since: Date) -> [Commit] {
        guard let email = GitService.output(["config", "user.email"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return [] }
        let branch = ["origin/HEAD", "origin/main", "origin/master"].first {
            GitService.output(["rev-parse", "--verify", "--quiet", $0], in: path) != nil
        } ?? "HEAD"
        let log = GitService.output(["log", branch, "--no-merges", "--author=\(email)", "--since=\(Int(since.timeIntervalSince1970))",
                                     "--format=%x1e%ct%x1f%s", "--name-only"], in: path) ?? ""
        return parseLog(log)
    }

    /// Pauses in every transcript Claude Code still keeps, in these folders (worktrees count for their project).
    static func pauses(in folders: [String], root: URL = UsageScanner.defaultRoot) -> [Pause] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        let paths = files.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" && !$0.path.contains("/subagents/") }
        let all = OSAllocatedUnfairLock(initialState: [Pause]())
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let found = (try? Data(contentsOf: paths[index], options: .alwaysMapped)).map(pauses(transcript:)) ?? []
            all.withLock { $0 += found }
        }
        return all.withLock { $0 }.filter { pause in folders.contains { pause.cwd == $0 || pause.cwd.hasPrefix($0 + "/") } }
    }
}

extension Impact {
    /// What IMPACT counts besides CI, read once per visit.
    struct Local {
        var entries: [Noticing.Entry] = []
        var commits: [Commit] = []
        var pauses: [Pause] = []
        var repos: [String] = []
    }

    /// For these folders (projects and the repos inside them, real paths): ~2 s, mostly transcripts.
    static func local(folders: [String], since: Date) async -> Local {
        let inFolders = { (path: String?) in path.map { path in folders.contains { path == $0 || path.hasPrefix($0 + "/") } } == true }
        return await Task.detached {
            let text = (try? String(contentsOf: Automations.historyFile, encoding: .utf8)) ?? ""
            var real: [String: String] = [:] // history.jsonl names the folder claude ran in; projects may be links
            let entries = Noticing.entries(historyLines: text.split(separator: "\n")).filter { entry in
                guard entry.date >= since, !entry.display.hasPrefix("/"), let project = entry.project else { return false }
                if real[project] == nil { real[project] = AppStore.realPath(project) }
                return inFolders(real[project])
            }
            let repos = Array(Set(folders.compactMap { GitService.output(["rev-parse", "--path-format=absolute", "--show-toplevel"], in: $0)?
                .trimmingCharacters(in: .whitespacesAndNewlines) }))
            return Local(entries: entries, commits: repos.flatMap { commits(in: $0, since: since) }, pauses: pauses(in: folders), repos: repos)
        }.value
    }

    /// GitHub Actions runs you started in these repos, side by side (several seconds); other hosts give none.
    static func ci(repos: [String], gh: String) async -> [CIRun] {
        guard let login = await CLI.run(gh, ["api", "user", "-q", ".login"], in: NSHomeDirectory())
            .flatMap({ String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }), !login.isEmpty else { return [] }
        return await withTaskGroup(of: [CIRun].self) { group in
            for repo in repos {
                group.addTask {
                    guard let data = await CLI.run(gh, ["run", "list", "-L", "200", "-u", login, "--json", GitHubActions.runFields], in: repo)
                    else { return [] }
                    return (try? GitHubActions.decoder.decode([CIRun].self, from: data)) ?? []
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
    }

    static func weeks(now: Date = .now, _ local: Local, ci: [CIRun]) -> [Week] {
        weeks(now: now, entries: local.entries, commits: local.commits, ci: ci, pauses: local.pauses, attribution: attribution())
    }

    static func since(now: Date = .now) -> Date { Calendar.current.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: weekStart(now))! }
}
