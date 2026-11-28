import Foundation
import GRDB

/// One project's week, as Home shows it: what was asked, what it cost, what got done.
struct ProjectWork: Equatable {
    var project: String
    var workspace: String?
    var promptsToday = 0
    var promptsWeek = 0
    var tokensWeek = 0
    var tasksDoneWeek = 0
}

/// What a project is built with, from its files: what the review weighs a technology against ("Kubernetes —
/// not yet: one service, docker compose").
enum TechStack {
    static func signals(at root: String) -> [String] {
        let fm = FileManager.default
        func has(_ path: String) -> Bool { fm.fileExists(atPath: root + "/" + path) }
        var signals: [String] = []
        for (file, name) in [("go.mod", "Go"), ("package.json", "Node/TypeScript"), ("pyproject.toml", "Python"),
                             ("requirements.txt", "Python"), ("Package.swift", "Swift"), ("project.yml", "Swift (XcodeGen)"),
                             ("pubspec.yaml", "Flutter"), ("build.gradle", "Gradle"), ("build.gradle.kts", "Gradle"),
                             ("Cargo.toml", "Rust"), ("Dockerfile", "Dockerfile"), ("docker-compose.yml", "docker compose"),
                             ("compose.yaml", "docker compose"), ("Chart.yaml", "Helm"), ("k8s", "Kubernetes"),
                             ("kubernetes", "Kubernetes"), ("helm", "Helm"), ("terraform", "Terraform"),
                             (".github/workflows", "GitHub Actions"), (".gitlab-ci.yml", "GitLab CI"),
                             ("migrations", "SQL migrations"), (".claude/skills", "project skills")]
        where has(file) && !signals.contains(name) { signals.append(name) }
        let tests = fm.enumerator(atPath: root).map { files in
            files.lazy.compactMap { $0 as? String }.prefix(20_000).contains { path in
                !path.contains("node_modules/") && !path.hasPrefix(".build/")
                    && (path.contains("_test.") || path.contains(".test.") || path.hasPrefix("tests/") || path.contains("Tests/"))
            }
        } ?? false
        if tests { signals.append("tests") }
        if let text = try? String(contentsOfFile: root + "/CLAUDE.md", encoding: .utf8) {
            signals.append("CLAUDE.md \(text.split(separator: "\n", omittingEmptySubsequences: false).count - 1) lines")
        }
        return signals
    }
}

/// The week as Claude reads it on Home's click: a summary, how to work better with Claude Code, and per project
/// which technology is due — or not yet — and why, as experienced engineers would weigh it.
struct WeekReview: Codable, Equatable {
    struct Tip: Codable, Equatable { var title: String; var why: String; var tryThis: String }
    struct Tech: Codable, Equatable {
        var project: String; var title: String; var verdict: String; var why: String; var tryThis: String
        /// The principle it follows from (one of `principles`' names).
        var principle: String?
    }
    /// How strong engineers and researchers work, found by searching their own writing, and where it shows (or
    /// doesn't) in the user's projects.
    struct Principle: Codable, Equatable {
        var name: String; var who: String; var why: String; var source: String; var inYourWork: String; var step: String
    }

    var summary: String
    var principles: [Principle]? = nil
    var claudeCode: [Tip]
    var tech: [Tech]
    var createdAt: Date?

    static let file = MeepoHome.url.appending(path: "review.json")
    /// Once a week on its own (AGAIN any time): Opus reads several projects (2026-11-28, the user's call: the better
    /// the advice, the more it's worth).
    static let refreshEvery: TimeInterval = 7 * 86400

    /// Opus (5.5 as of 2026-11-28), reading the week's busiest projects (up to 6) with read-only tools.
    /// `folders`: each project's folder and the repos it links to (Glob doesn't follow links: ~/Projects/taxi is 3).
    static func arguments(work: [ProjectWork], folders: [String: [String]]) -> (model: String, tools: String, extra: [String]) {
        let busiest = work.filter { $0.promptsWeek > 0 }.sorted { $0.promptsWeek > $1.promptsWeek }.prefix(6)
        let tools = "Read,Grep,Glob,WebSearch,WebFetch"
        // Headless, nobody to ask: the web tools need an allow rule; reading inside the added folders doesn't.
        return ("opus", tools, ["--allowedTools", "WebSearch WebFetch", "--add-dir", changelog]
            + busiest.flatMap { folders[$0.project] ?? [] }.flatMap { ["--add-dir", $0] })
    }

    /// A project's folder, then the folders its top-level links point to.
    static func readableFolders(of path: String) -> [String] {
        let fm = FileManager.default
        let linked = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted().compactMap { name -> String? in
            let item = path + "/" + name
            guard (try? fm.destinationOfSymbolicLink(atPath: item)) != nil else { return nil }
            let target = URL(filePath: item).resolvingSymlinksInPath().path
            var isFolder: ObjCBool = false
            return fm.fileExists(atPath: target, isDirectory: &isFolder) && isFolder.boolValue ? target : nil
        }
        return [path] + linked
    }

    static let schema = """
        {"type":"object","required":["summary","principles","claudeCode","tech"],"additionalProperties":false,"properties":{
         "summary":{"type":"string"},
         "principles":{"type":"array","minItems":3,"maxItems":5,"items":{"type":"object",
           "required":["name","who","why","source","inYourWork","step"],"additionalProperties":false,"properties":{
             "name":{"type":"string"},"who":{"type":"string"},"why":{"type":"string"},"source":{"type":"string"},
             "inYourWork":{"type":"string"},"step":{"type":"string"}}}},
         "claudeCode":{"type":"array","maxItems":4,"items":{"type":"object","required":["title","why","tryThis"],"additionalProperties":false,
           "properties":{"title":{"type":"string"},"why":{"type":"string"},"tryThis":{"type":"string"}}}},
         "tech":{"type":"array","maxItems":5,"items":{"type":"object","required":["project","title","verdict","why","tryThis","principle"],
           "additionalProperties":false,"properties":{"project":{"type":"string"},"title":{"type":"string"},
             "verdict":{"type":"string","enum":["now","not yet","drop it"]},"why":{"type":"string"},"tryThis":{"type":"string"},
             "principle":{"type":"string"}}}}}}
        """

    /// The week's habits from ~/.meepo/behavior.jsonl, counted: what the review reads about how the user works.
    static func habits(from log: String, since start: Date) -> [String: Int] {
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)
        var counts: [String: Int] = [:]
        var hours = Set<Int>()
        for line in log.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                  let date = object["t"].flatMap({ try? iso.parse($0) }), date >= start else { continue }
            let label: String? = switch (object["kind"], object["event"], object["key"]) {
            case ("key", _, "esc"): "interrupts (Esc)"
            case ("hook", "PermissionRequest", _): "permission requests"
            case ("hook", "UserPromptSubmit", _): "prompts"
            case ("hook", "Notification", _): "times Claude waited for you"
            case ("view", _, _) where object["field"] == "session": "session switches"
            default: nil
            }
            if let label { counts[label, default: 0] += 1 }
            if object["kind"] == "hook" { hours.insert(Calendar.current.component(.hour, from: date)) }
        }
        if !hours.isEmpty { counts["distinct working hours of the day"] = hours.count }
        return counts
    }

    /// Claude Code keeps its own changelog here, newest first (ClaudeChangelog reads it too).
    static let changelog = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/cache").path

    static func prompt(work: [ProjectWork], stacks: [String: [String]], habits: [String: Int], language: String) -> String {
        let changelog = Self.changelog + "/changelog.md"
        let rows = work.map { w in
            "- \(w.project)\(w.workspace.map { " (workspace \($0))" } ?? ""): \(w.promptsWeek) prompts, \(w.tokensWeek) tokens, "
                + "\(w.tasksDoneWeek) tasks done; stack: \((stacks[w.project] ?? []).joined(separator: ", "))"
        }.joined(separator: "\n")
        let habitLines = habits.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
        return """
            You are a mentor to one developer: a backend engineer who works with Claude Code, runs several sessions in \
            parallel, and has projects that integrate with each other. Review their last 7 days. The advice must be the \
            kind the best engineers would give — not checklist advice.

            Work in this order:
            1. Research first (WebSearch, WebFetch). Find how today's strongest engineers and researchers work: which \
            practices and tools they study and adopt, and why — and which they drop. Go to primary sources: their own \
            writing, engineering blogs of strong teams, books, talks, papers. Look at least at how they work with AI \
            coding agents, how they keep systems reliable, and how they keep integrated services in agreement. \
            Start with the people who build Claude Code and see how it's used most: anthropic.com/engineering (Anthropic \
            engineers' own reports of how they work), anthropic.com/research, claude.com/blog, the Claude Code docs' best \
            practices (code.claude.com/docs), and the Claude Code page on LinkedIn (linkedin.com/company/claude-code/posts \
            — skip it if it needs a login). What Claude Code shipped lately is in \(changelog) (Read it): new features \
            they would already use. Then go wider: strong teams' engineering blogs, well-known engineers' writing, \
            books, talks, papers. At least 4 different sources.
            2. Distill 3–5 principles from that — the reasons behind the tools, not the tools. A principle is worth \
            keeping only if it fits this developer's situation below.
            3. Read their projects (Read, Grep, Glob — change nothing): README, CLAUDE.md, dependencies, Docker, CI, \
            how the code and the services between projects are laid out. Find where each principle is already practised \
            and where it is missing — with file paths.
            4. Only then recommend. Every recommendation follows from a principle; don't recommend a tool because it is \
            popular or because of the project's size alone.

            Their projects this week:
            \(rows)

            Their habits this week (from their app's log — it may cover only part of the week, so don't read low counts \
            as the week's total and don't comment on the logging itself):
            \(habitLines.isEmpty ? "- not recorded yet" : habitLines)

            Write in \(language). Concrete, grounded in what you found and read; nothing generic.
            - summary: 2–3 sentences: where the week went and the one thing that would change their work most.
            - principles: name; who practises it (people or teams, by name); why it works; source (one URL you read); \
            inYourWork (where it shows or is missing in their projects, with paths); step (a first step today).
            - claudeCode: up to 4 ways to work better with Claude Code, from the principles and these habits; tryThis is \
            one step for today.
            - tech: up to 5 calls on tools and practices for their projects — adopt now, not yet, or drop — each naming \
            the principle it follows from (`principle`), why, and a first small step naming the files it touches.
            """
    }

    static func load() -> WeekReview? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WeekReview.self, from: data)
    }
}

extension AppStore {
    /// Prompts per project from history.jsonl entries (every prompt in every session, Meepo's or not — hook events
    /// see only Meepo's live sessions): each to the project whose folder holds where claude ran, the deepest one.
    static func promptCounts(_ entries: [Noticing.Entry], projects: [(id: Int64, path: String)], dayStart: Date) -> [Int64: (today: Int, week: Int)] {
        var counts: [Int64: (today: Int, week: Int)] = [:]
        let byDepth = projects.sorted { $0.path.count > $1.path.count }
        for entry in entries {
            guard let folder = entry.project,
                  let project = byDepth.first(where: { folder == $0.path || folder.hasPrefix($0.path + "/") }) else { continue }
            var count = counts[project.id] ?? (0, 0)
            count.week += 1
            if entry.date >= dayStart { count.today += 1 }
            counts[project.id] = count
        }
        return counts
    }

    /// Per project in the last 7 days: prompts (today too, from `entries`, history.jsonl's), tokens and tasks done.
    /// Busiest first; projects with nothing this week left out.
    func workWeek(now: Date = .now, entries: [Noticing.Entry]) -> [ProjectWork] {
        let weekStart = now.addingTimeInterval(-7 * 86400), dayStart = Calendar.current.startOfDay(for: now)
        var rows = Dictionary(uniqueKeysWithValues: projects.compactMap { p in p.id.map { ($0, ProjectWork(project: p.name, workspace: p.workspace)) } })
        let prompts = Self.promptCounts(entries.filter { $0.date >= weekStart },
                                        projects: projects.compactMap { p in p.id.map { ($0, p.path) } }, dayStart: dayStart)
        for (id, count) in prompts { rows[id]?.promptsToday = count.today; rows[id]?.promptsWeek = count.week }
        try? db.read { db in
            for row in try Row.fetchAll(db, sql: "SELECT projectId AS p, COUNT(*) AS n FROM task WHERE isDone = 1 AND doneAt >= ? AND projectId IS NOT NULL GROUP BY projectId",
                                        arguments: [weekStart]) {
                rows[row["p"] as Int64]?.tasksDoneWeek = row["n"] ?? 0
            }
        }
        for (name, totals) in usageStats(since: weekStart).byProject {
            if let id = rows.first(where: { $0.value.project == name })?.key { rows[id]?.tokensWeek = totals.total }
        }
        return rows.values.filter { $0.promptsWeek + $0.tokensWeek + $0.tasksDoneWeek > 0 }
            .sorted { ($0.promptsWeek, $0.tokensWeek) > ($1.promptsWeek, $1.tokensWeek) }
    }

    /// The last 7 days of ~/.claude/history.jsonl, read off the main thread (it grows by megabytes).
    static func weekOfHistory(now: Date = .now) async -> [Noticing.Entry] {
        await Task.detached {
            let text = (try? String(contentsOf: Automations.historyFile, encoding: .utf8)) ?? ""
            let start = now.addingTimeInterval(-7 * 86400)
            return Noticing.entries(historyLines: text.split(separator: "\n")).filter { $0.date >= start }
        }.value
    }

    /// Home's REVIEW MY WEEK: one `claude -p` over the numbers, the projects' stacks and the habits; kept in
    /// ~/.meepo/review.json until the next click.
    func reviewWeek() async throws -> WeekReview {
        guard let login = loginEnvironment else { throw ClaudeHeadless.Failure(errorDescription: "claude isn't found in the login shell") }
        let entries = await Self.weekOfHistory()
        let work = workWeek(entries: entries)
        let paths = Dictionary(projects.map { ($0.name, $0.path) }) { first, _ in first }
        let stacks = await Task.detached {
            Dictionary(uniqueKeysWithValues: work.map { ($0.project, paths[$0.project].map(TechStack.signals(at:)) ?? []) })
        }.value
        let log = (try? String(contentsOf: MeepoHome.url.appending(path: "behavior.jsonl"), encoding: .utf8)) ?? ""
        // Prompts come from history.jsonl (in `work`); the log's own count starts later and would contradict it.
        let habits = WeekReview.habits(from: log, since: .now.addingTimeInterval(-7 * 86400)).filter { $0.key != "prompts" }
        let language = Self.writesRussian(entries) ? "Russian" : GitPanel.userLanguage
        let prompt = WeekReview.prompt(work: work, stacks: stacks, habits: habits, language: language)
        let folders = await Task.detached { paths.mapValues(WeekReview.readableFolders(of:)) }.value
        let args = WeekReview.arguments(work: work, folders: folders)
        let data = try await ClaudeHeadless.askJSON(prompt, schema: WeekReview.schema, claude: login.claudePath,
                                                    environment: login.environment, tools: args.tools, model: args.model,
                                                    extra: args.extra)
        var review = try JSONDecoder().decode(WeekReview.self, from: data)
        review.createdAt = .now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(review).write(to: WeekReview.file)
        return review
    }
}
