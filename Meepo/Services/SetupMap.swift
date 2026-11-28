import Foundation

/// What Home knows about how the user works this week, read from Claude Code's own files and Meepo's logs.
struct SetupFacts {
    var prompts = 0, promptsToday = 0, imagePrompts = 0, scheduled = 0
    var userClaudeMdLines = 0, personalSkills = 0, projectsWithCheck = 0, projects = 0
    var mcpServers: [String] = []
    var outputStyle: String?
    var interrupts = 0, permissionRequests = 0, maxParallel = 0
    /// The user writes their prompts in Russian: Home and the review speak it (2026-11-28, the user asked).
    var isRussian = false
    /// Project, its share of the week's prompts, tasks done.
    var byProject: [(name: String, share: Double, tasksDone: Int)] = []
}

/// The user's Claude Code setup level by level (context, skills, agents, tools, taste — as people who get the
/// most out of Claude lay it out), and the few next steps worth taking this week. Counted, no model call.
enum SetupMap {
    enum State { case done, partly, missing }
    struct Item { var name: String; var state: State; var detail: String }
    struct Level { var name: String; var items: [Item] }
    struct Step { var title: String; var evidence: String; var task: String }

    static func levels(_ f: SetupFacts) -> [Level] {
        func item(_ name: String, _ ok: Bool, _ partly: Bool = false, _ detail: String) -> Item {
            Item(name: name, state: ok ? .done : partly ? .partly : .missing, detail: detail)
        }
        let t = { (en: String, ru: String) in f.isRussian ? ru : en }
        return [
            Level(name: t("Context", "Контекст"), items: [
                item(t("CLAUDE.md about you", "CLAUDE.md о тебе"), f.userClaudeMdLines >= 10, f.userClaudeMdLines > 0, "~/.claude/CLAUDE.md, \(f.userClaudeMdLines) \(t("lines", "строк"))"),
                item(t("Screenshots over words", "Скриншоты вместо слов"), f.imagePrompts * 10 >= max(f.prompts, 1), f.imagePrompts > 0, t("\(f.imagePrompts) of \(f.prompts) prompts", "\(f.imagePrompts) из \(f.prompts) запросов")),
            ]),
            Level(name: "Skills", items: [
                item(t("A skill per repeated task", "Skill на повторяемую задачу"), f.personalSkills >= 3, f.personalSkills > 0, t("\(f.personalSkills) of your own", "своих: \(f.personalSkills)")),
            ]),
            Level(name: t("Agents", "Агенты"), items: [
                item(t("Checks after each answer", "Проверка после ответа"), f.projects > 0 && f.projectsWithCheck == f.projects, f.projectsWithCheck > 0,
                     t("\(f.projectsWithCheck) of \(f.projects) projects", "\(f.projectsWithCheck) из \(f.projects) проектов")),
                item(t("Parallel sessions", "Параллельные сессии"), f.maxParallel >= 2, false, t("up to \(f.maxParallel) at once", "до \(f.maxParallel) одновременно")),
                item(t("Scheduled runs", "Запуски по расписанию"), f.scheduled > 0, false, "/loop, /schedule: \(f.scheduled)×"),
            ]),
            Level(name: t("Tools", "Инструменты"), items: [
                item(t("MCP connectors", "MCP-коннекторы"), f.mcpServers.count >= 2, !f.mcpServers.isEmpty,
                     f.mcpServers.isEmpty ? t("none seen yet", "пока не видно") : f.mcpServers.joined(separator: ", ")),
            ]),
            Level(name: t("Taste", "Стиль"), items: [
                item(t("Your own output style", "Свой стиль ответов"), f.outputStyle != nil, false, f.outputStyle ?? t("default", "стандартный")),
            ]),
        ]
    }

    /// The most costly habits first: each step says what it saw and becomes a task on a click.
    static func steps(_ f: SetupFacts) -> [Step] {
        let t = { (en: String, ru: String) in f.isRussian ? ru : en }
        var steps: [(weight: Double, step: Step)] = []
        let prompts = Double(max(f.prompts, 1))
        if f.permissionRequests * 4 >= f.prompts, f.permissionRequests >= 10 {
            steps.append((Double(f.permissionRequests) / prompts, Step(
                title: t("Allow the commands Claude keeps asking for", "Разреши команды, о которых Claude всё время спрашивает"),
                evidence: t("\(f.permissionRequests) permission requests on \(f.prompts) prompts", "\(f.permissionRequests) запросов разрешения на \(f.prompts) твоих запросов"),
                task: t("Run /fewer-permission-prompts: allow the read-only commands Claude keeps asking for", "Запусти /fewer-permission-prompts: разреши безопасные команды, о которых Claude спрашивает чаще всего"))))
        }
        if f.interrupts * 8 >= f.prompts, f.interrupts >= 5 {
            steps.append((Double(f.interrupts) / prompts, Step(
                title: t("Plan first on bigger tasks", "Сначала план на больших задачах"),
                evidence: t("\(f.interrupts) interrupts (Esc) on \(f.prompts) prompts — a turn went the wrong way", "\(f.interrupts) прерываний (Esc) на \(f.prompts) запросов — ход уходил не туда"),
                task: t("Start tasks that touch more than two files in plan mode (Shift+Tab), approve the plan, then build", "Задачи больше чем на два файла начинай в plan mode (Shift+Tab): утверди план, потом делай"))))
        }
        if f.projects > 0, f.projectsWithCheck < f.projects {
            steps.append((0.1, Step(
                title: t("Give every project a check", "Дай каждому проекту проверку"),
                evidence: t("\(f.projects - f.projectsWithCheck) of \(f.projects) projects end turns without build or tests", "\(f.projects - f.projectsWithCheck) из \(f.projects) проектов заканчивают ход без сборки и тестов"),
                task: t("Set a check command (build, tests) for each project in meepo, so Claude can't finish on a broken build", "Задай проектам команду проверки (сборка, тесты) в meepo — Claude не закончит на сломанной сборке"))))
        }
        if f.userClaudeMdLines < 10 {
            steps.append((0.05, Step(
                title: t("Tell Claude who you are", "Расскажи Claude, кто ты"),
                evidence: t("~/.claude/CLAUDE.md has \(f.userClaudeMdLines) lines", "в ~/.claude/CLAUDE.md \(f.userClaudeMdLines) строк"),
                task: t("Write ~/.claude/CLAUDE.md: who I am, how I work, how I want answers", "Напиши ~/.claude/CLAUDE.md: кто я, как работаю, какие ответы мне нужны"))))
        }
        return steps.sorted { $0.weight > $1.weight }.map(\.step)
    }

    static func summary(_ f: SetupFacts) -> String {
        let t = { (en: String, ru: String) in f.isRussian ? ru : en }
        var text = t("\(f.prompts) prompts (\(f.promptsToday) today).", "\(f.prompts) запросов (сегодня \(f.promptsToday)).")
        if let top = f.byProject.max(by: { $0.share < $1.share }), top.share > 0 {
            let share = Int((top.share * 100).rounded())
            text += t(" Most went to \(top.name) (\(share)%)", " Больше всего — \(top.name) (\(share)%)")
            text += top.tasksDone > 0 ? t(", \(top.tasksDone) tasks done there.", ", закрыто задач: \(top.tasksDone).") : "."
        }
        return text
    }
}

extension AppStore {
    /// Most of the user's recent prompts are in Cyrillic: Home and the review speak Russian.
    nonisolated static func writesRussian(_ entries: [Noticing.Entry]) -> Bool {
        let letters = entries.suffix(200).flatMap { $0.display.unicodeScalars.filter { CharacterSet.letters.contains($0) } }
        let cyrillic = letters.filter { (0x0400...0x04FF).contains($0.value) }.count
        return !letters.isEmpty && cyrillic * 2 >= letters.count
    }

    /// Read off the main thread where it's files: history.jsonl, behavior.jsonl, settings, skills.
    func setupFacts(now: Date = .now) async -> SetupFacts {
        let entries = inWorkspace(await Self.weekOfHistory(now: now)) // the workspace shown, or every project
        let week = workWeek(now: now, entries: entries)
        let total = Double(max(week.reduce(0) { $0 + $1.promptsWeek }, 1))
        let mcp = Set(contextUsage.values.flatMap { $0.mcp.map(\.server) }).sorted()
        let shown = workspaceProjects
        let projectCount = shown.count, withCheck = shown.filter { !($0.checkCommand ?? "").isEmpty }.count
        var facts = await Task.detached { () -> SetupFacts in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let start = now.addingTimeInterval(-7 * 86400), dayStart = Calendar.current.startOfDay(for: now)
            var f = SetupFacts()
            f.prompts = entries.count
            f.promptsToday = entries.filter { $0.date >= dayStart }.count
            f.imagePrompts = entries.filter { $0.display.contains("[Image #") }.count
            f.scheduled = entries.filter { $0.display.hasPrefix("/loop") || $0.display.hasPrefix("/schedule") }.count
            f.userClaudeMdLines = ((try? String(contentsOf: home.appending(path: ".claude/CLAUDE.md"), encoding: .utf8)) ?? "")
                .split(separator: "\n").count
            f.personalSkills = ((try? FileManager.default.contentsOfDirectory(atPath: home.appending(path: ".claude/skills").path)) ?? [])
                .filter { !$0.hasPrefix(".") }.count
            let settings = (try? Data(contentsOf: home.appending(path: ".claude/settings.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            f.outputStyle = settings?["outputStyle"] as? String
            let log = (try? String(contentsOf: MeepoHome.url.appending(path: "behavior.jsonl"), encoding: .utf8)) ?? ""
            let habits = WeekReview.habits(from: log, since: start)
            f.interrupts = habits["interrupts (Esc)"] ?? 0
            f.permissionRequests = habits["permission requests"] ?? 0
            f.maxParallel = log.split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])?["working"].flatMap(Int.init)
            }.max() ?? 0
            return f
        }.value
        facts.projects = projectCount
        facts.projectsWithCheck = withCheck
        facts.mcpServers = mcp
        facts.byProject = week.map { ($0.project, Double($0.promptsWeek) / total, $0.tasksDoneWeek) }
        facts.isRussian = Self.writesRussian(entries)
        return facts
    }
}
