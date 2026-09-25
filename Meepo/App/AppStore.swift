import Foundation
import GRDB
import Observation
import SwiftTerm
import WidgetKit

enum AddProjectError: LocalizedError, Equatable {
    case alreadyAdded(String)

    var errorDescription: String? {
        switch self {
        case .alreadyAdded(let name): "Project “\(name)” is already added"
        }
    }
}

@MainActor
@Observable
final class AppStore {
    private let db: DatabaseQueue
    private let terminals = TerminalRegistry()
    private let bridge: BridgeInstaller
    private let usageRoot: URL
    /// Injected so tests (which run inside the app, same bundle id) never touch the user's settings.
    private let defaults: UserDefaults
    /// First prompt of a freshly created session; used once, never stored.
    private(set) var initialPrompts: [Int64: String] = [:]
    private(set) var loginEnvironment: ClaudeLauncher.LoginEnvironment?
    /// Sessions wait for the login environment (~0.6 s at launch) so they never race into the shell fallback.
    /// The login shell has been asked for claude's path and environment (see `loginEnvironment`).
    private(set) var isLoginResolved = false

    private(set) var projects: [Project] = []
    private(set) var sessions: [Session] = []
    private(set) var runningSessionIds: Set<Int64> = []
    private(set) var exitedSessionIds: Set<Int64> = []
    var selectedSessionId: Int64? {
        didSet {
            reloadEvents()
            isHomeShown = false
            if let id = selectedSessionId, paneAnchor.map({ paneWindow(from: $0, count: shell.split).contains(id) }) != true {
                paneAnchor = id
            }
        }
    }
    /// Non-nil while the "new session" sheet is shown; the project preselected in it.
    var newSessionProjectId: Int64?
    /// Feed of the selected session, newest first.
    private(set) var selectedEvents: [HookEvent] = []
    private(set) var isBridgeInstalled = false
    /// Last bridge/event-server problem to show the user.
    var bridgeError: String?
    /// False when macOS refuses Meepo's notifications (turned off in System Settings).
    var notificationsAllowed = true

    private static let eventRetention: TimeInterval = 7 * 24 * 3600
    private static let feedLimit = 200

    init(db: DatabaseQueue, bridge: BridgeInstaller = BridgeInstaller(), usageRoot: URL = UsageScanner.defaultRoot,
         defaults: UserDefaults = .standard) {
        self.db = db
        self.bridge = bridge
        self.usageRoot = usageRoot
        self.defaults = defaults
        contextWindows = Self.load([String: Int].self, Self.contextWindowsKey, from: defaults) ?? [:]
        stages = Self.load([Stage].self, Self.stagesKey, from: defaults) ?? Stage.defaults
        guidedMode = defaults.bool(forKey: Self.guidedKey)
        suggestionStates = Self.load([String: SuggestionState].self, Self.suggestionsKey, from: defaults) ?? [:]
        chains = Self.load([[String]].self, Self.chainsKey, from: defaults) ?? []
        chainRuns = (defaults.dictionary(forKey: Self.chainRunsKey) as? [String: Int]) ?? [:]
        let preset = defaults.string(forKey: Self.shellPresetKey).flatMap(ShellLayout.Preset.init(rawValue:)) ?? .focus
        shellPreset = preset
        shell = Self.load(ShellLayout.self, Self.shellKey, from: defaults) ?? ShellLayout.preset(preset) ?? ShellLayout.preset(.focus)!
        relayThreshold = defaults.object(forKey: Self.relayThresholdKey) as? Double ?? 0.7
        remoteControlForNewSessions = defaults.bool(forKey: Self.remoteControlKey)
        autofixProjectIds = Set((defaults.array(forKey: Self.autofixKey) as? [Int64]) ?? [])
        fixAttempts = (defaults.dictionary(forKey: Self.fixAttemptsKey) as? [String: Int]) ?? [:]
        screenshotHotKey = defaults.string(forKey: Self.shotHotKeyKey) ?? "⌘⇧6"
        autoUpdate = defaults.object(forKey: Self.autoUpdateKey) as? Bool ?? true
        updateChannel = defaults.string(forKey: Self.channelKey).flatMap(Updater.Channel.init(rawValue:))
            ?? (Updater.currentVersion?.isPrerelease ?? true ? .beta : .stable)
        libraryFolder = defaults.string(forKey: Self.libraryKey)
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude").path
        // A session that was mid-turn when Meepo went away (quit, restart, crash) lost that turn; say so.
        interruptedSessionIds = Set((try? db.read {
            try Int64.fetchAll($0, sql: "SELECT id FROM session WHERE status = ?", arguments: [SessionStatus.thinking])
        }) ?? [])
        lastCrashReport = CrashReports.latest(since: Self.crashesSeen(defaults), in: CrashReports.folder)
        // Processes restart with Meepo, so statuses from the previous run are stale.
        _ = try? db.write { db in
            try db.execute(sql: "UPDATE session SET status = ?", arguments: [SessionStatus.idle])
            try db.execute(sql: "DELETE FROM hookEvent WHERE createdAt < ?",
                           arguments: [Date.now.addingTimeInterval(-Self.eventRetention)])
        }
        reload()
        reloadTasks()
        reloadReleaseNotes()
        selectedSessionId = orderedSessions.first?.id
        isBridgeInstalled = bridge.isInstalled()
        terminals.onExit = { [weak self] id in
            self?.runningSessionIds.remove(id)
            self?.exitedSessionIds.insert(id)
        }
    }

    /// Resolves the login shell environment once, then brings every saved session back
    /// in the background so switching to it is instant.
    func restoreSessions() async {
        await resolveLogin()
    }

    /// Asks the login shell for claude again (after installing it, or fixing ~/.zshrc) and starts the sessions.
    func resolveLogin() async {
        isLoginResolved = false
        loginEnvironment = await Task.detached { ClaudeLauncher.resolveLoginEnvironment() }.value
        isLoginResolved = true
        for session in orderedSessions {
            if let id = session.id { startTerminalIfNeeded(id) }
        }
        if let login = loginEnvironment {
            let output = await Task.detached { ClaudeLauncher.versionOutput(login: login) }.value
            let changelog = await Task.detached { try? String(contentsOf: ClaudeChangelog.cacheFile, encoding: .utf8) }.value
            if let version = output.flatMap(ClaudeChangelog.version(fromCLI:)) { noteClaudeVersion(version, changelog: changelog ?? "") }
        }
        await checkClaudeLogin()
    }

    // MARK: Session names

    /// What to call a session: the user's name for it, else Claude Code's (after /rename), else its first
    /// request — so two sessions of one project read differently everywhere.
    func displayName(of session: Session) -> String {
        if let name = session.name { return name }
        if let id = session.id, let named = liveStatus[id]?.sessionName, !named.isEmpty { return named }
        if let id = session.id, let first = firstRequest(of: id) { return Notifier.plainText(first, limit: 40) }
        return session.worktreeName.map { "worktree \($0)" } ?? session.branch ?? "session"
    }

    private func firstRequest(of sessionId: Int64) -> String? {
        try? db.read { db in
            try String.fetchOne(db, sql: """
                SELECT summary FROM hookEvent WHERE sessionId = ? AND name = 'UserPromptSubmit' AND summary <> ''
                ORDER BY createdAt, id LIMIT 1
                """, arguments: [sessionId])
        }
    }

    /// The session whose Rename box is open.
    var renamingSessionId: Int64?

    /// Renames in Meepo, and in Claude Code too when the session is running (`/rename` works mid-turn).
    func rename(_ sessionId: Int64, to name: String) {
        guard var session = sessions.first(where: { $0.id == sessionId }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.name = clean.isEmpty ? nil : clean
        _ = try? db.write { try session.update($0) }
        reload()
        if !clean.isEmpty, runningSessionIds.contains(sessionId) { type("/rename \(clean)\r", into: sessionId) }
    }

    // MARK: Onboarding — the two ways in

    private static let guidedKey = "guidedMode"

    /// For people new to Claude Code: Meepo's sessions explain as they go and ask before risky commands.
    /// Takes effect for sessions started (or restarted) after the change.
    var guidedMode: Bool {
        didSet { defaults.set(guidedMode, forKey: Self.guidedKey) }
    }

    /// `claude auth status` after the login shell is known; nil = couldn't tell.
    private(set) var isClaudeLoggedIn: Bool?

    func checkClaudeLogin() async {
        guard let login = loginEnvironment else { isClaudeLoggedIn = nil; return }
        isClaudeLoggedIn = await Task.detached { ClaudeLauncher.isLoggedIn(login: login) }.value
    }

    /// A new, empty project: the folder, `git init` (so changes are tracked and can be compared), added to Meepo.
    @discardableResult
    func createProject(named name: String, in parent: URL) throws -> Project? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/") else { throw ClaudeHeadless.Failure(errorDescription: "Give the project a name") }
        let folder = parent.appending(path: clean)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw ClaudeHeadless.Failure(errorDescription: "\(folder.path) already exists — add it with + instead")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let error = GitService.runReportingError(["init", "-q"], in: folder.path) { throw ClaudeHeadless.Failure(errorDescription: error) }
        try addProject(at: folder)
        let real = folder.resolvingSymlinksInPath().path // /var vs /private/var and the like
        return projects.first { URL(filePath: $0.path).resolvingSymlinksInPath().path == real }
    }

    // MARK: Claude Code's version and what's new in it

    private static let claudeSeenKey = "claudeCodeVersionSeen"
    private(set) var claudeVersion: String?
    /// What changed since the version the user last acknowledged, newest first; empty = nothing new.
    private(set) var claudeNews: [ClaudeChangelog.Release] = []
    private(set) var claudeNewsSince: String?

    /// On the first run the current version just becomes the baseline — no wall of old news.
    func noteClaudeVersion(_ version: String, changelog: String) {
        claudeVersion = version
        guard let seen = defaults.string(forKey: Self.claudeSeenKey) else {
            defaults.set(version, forKey: Self.claudeSeenKey)
            return
        }
        guard let old = Updater.Version(seen), let new = Updater.Version(version), new > old else { return }
        claudeNewsSince = seen
        claudeNews = ClaudeChangelog.releases(in: changelog, after: seen, upTo: version)
    }

    func acknowledgeClaudeNews() {
        if let claudeVersion { defaults.set(claudeVersion, forKey: Self.claudeSeenKey) }
        claudeNews = []
        claudeNewsSince = nil
    }

    // MARK: Claude Code setup check

    /// What in ~/.claude works against the user right now (see SetupCheck).
    func setupFindings() -> [SetupCheck.Finding] {
        let settings = (try? bridge.readSettings()) ?? [:]
        // byModel comes from GROUP BY without an order; the most used one is picked here.
        let topModel = usageStats(since: .now.addingTimeInterval(-7 * 24 * 3600)).byModel
            .filter { $0.name.hasPrefix("claude-") }.max { $0.totals.total < $1.totals.total }?.name
        return SetupCheck.findings(settings: settings, topModel: topModel,
                                   commands: SetupCheck.userCommands(claudeHome: bridge.settingsURL.deletingLastPathComponent()))
    }

    /// Applies a finding's fix, or takes exactly that fix back (`undo`). Logged in Tools → Changes either way.
    func setSetupFix(_ finding: SetupCheck.Finding, applied: Bool) throws {
        switch finding.fix {
        case let .settings(apply, undo):
            try bridge.editSettings((applied ? "" : "Undo: ") + finding.fixTitle, applied ? apply : undo)
        case let .manualOnly(file):
            let text = try String(contentsOf: file, encoding: .utf8)
            let backup = try ChangeLog.backup(file, folder: "skills", backups: backupsDir)
            try SetupCheck.setManualOnly(text, applied).write(to: file, atomically: true, encoding: .utf8)
            ChangeLog.record((applied ? "" : "Undo: ") + "\(finding.fixTitle): \(file.lastPathComponent)", file: file,
                             backup: backup, backups: backupsDir)
        }
    }

    // MARK: What changed — runs and what they mean for the product's users

    /// Explanations being written right now, by run id.
    private(set) var explainingRuns: Set<String> = []

    /// The session's runs over the events Meepo keeps (7 days), newest first.
    func runs(of sessionId: Int64) -> [Run] {
        let events = (try? db.read { try HookEvent.filter(Column("sessionId") == sessionId).fetchAll($0) }) ?? []
        return Runs.from(events).reversed()
    }

    func summary(of run: Run) -> ProductSummary? {
        let json = try? db.read { db in
            try String.fetchOne(db, sql: "SELECT json FROM runSummary WHERE sessionId = ? AND startedAt = ?",
                                arguments: [run.sessionId, run.startedAt])
        }
        return json.flatMap { try? JSONDecoder().decode(ProductSummary.self, from: Data($0.utf8)) }
    }

    /// Asks a fork of the session's own conversation what the run changed for users — on click only, then kept.
    func explain(_ run: Run) async throws -> ProductSummary {
        guard let login = loginEnvironment else { throw ClaudeHeadless.Failure(errorDescription: "claude isn't found in the login shell") }
        guard let session = sessions.first(where: { $0.id == run.sessionId }), let folder = workdir(of: session) else {
            throw ClaudeHeadless.Failure(errorDescription: "The session is gone")
        }
        explainingRuns.insert(run.id)
        defer { explainingRuns.remove(run.id) }
        let data = try await ClaudeHeadless.askFork(of: session.claudeSessionId, in: folder,
                                                    prompt: Runs.prompt(for: run, language: GitPanel.userLanguage),
                                                    schema: Runs.schema, claude: login.claudePath, environment: login.environment)
        let summary = try JSONDecoder().decode(ProductSummary.self, from: data)
        let json = String(decoding: data, as: UTF8.self)
        try await db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO runSummary (sessionId, startedAt, json, createdAt) VALUES (?, ?, ?, ?)
                """, arguments: [run.sessionId, run.startedAt, json, Date.now])
        }
        return summary
    }

    /// Something listening in the session's own port range (PORT…PORT+9): its preview, if it has one running.
    func previewURL(of session: Session) async -> URL? {
        guard let base = session.portBase else { return nil }
        let ports = await Task.detached { Ports.listening().map(\.port) }.value
        return ports.first { (base..<base + Ports.blockSize).contains($0) }.flatMap { URL(string: "http://localhost:\($0)") }
    }

    /// Claude Code's own checkpoint picker: it puts back what Claude's edits changed, not what shell commands did.
    func rewind(_ sessionId: Int64) {
        type("/rewind\r", into: sessionId)
    }

    // MARK: Noticing — suggestions from the user's own history, applied with their say-so, then measured

    struct SuggestionState: Codable, Equatable {
        var dismissedAt: Int?     // the count when "Not now" was clicked; it comes back once that doubles
        var appliedAt: Date?
    }

    private static let suggestionsKey = "suggestionStates"
    private static let chainsKey = "chains"
    private static let chainRunsKey = "chainRuns"

    private(set) var suggestionStates: [String: SuggestionState] = [:]
    /// Everything noticed in history, newest reading; `visibleSuggestions` filters what the user already answered.
    private(set) var suggestions: [Noticing.Suggestion] = []
    /// Command chains the user turned into buttons, e.g. ["simplify", "ship", "sync"].
    private(set) var chains: [[String]] = []
    /// How many times each chain ran to the end — the measure for an applied chain.
    private(set) var chainRuns: [String: Int] = [:]
    /// Chains running now: which step comes next; `paused` when Claude ended a step with a question.
    private(set) var runningChains: [Int64: (commands: [String], next: Int, paused: Bool)] = [:]

    var visibleSuggestions: [Noticing.Suggestion] {
        suggestions.filter { suggestion in
            let state = suggestionStates[suggestion.id]
            guard state?.appliedAt == nil else { return false }
            return state?.dismissedAt.map { suggestion.count >= 2 * $0 } ?? true
        }
    }

    /// Reads history.jsonl off the main thread and finds chains and repeated requests.
    func refreshSuggestions() async {
        let known = Set(commandsByProject.values.flatMap { $0.map(\.name) } + CommandCatalog.builtIns.map(\.name))
        suggestions = await Task.detached {
            let text = (try? String(contentsOf: Automations.historyFile, encoding: .utf8)) ?? ""
            let entries = Noticing.entries(historyLines: text.split(separator: "\n"))
            let since = Date.now.addingTimeInterval(-Noticing.window)
            return Noticing.chains(entries, known: known, since: since) + Noticing.repeatedPrompts(entries, since: since)
        }.value
    }

    func dismissSuggestion(_ suggestion: Noticing.Suggestion) {
        suggestionStates[suggestion.id, default: SuggestionState()].dismissedAt = suggestion.count
        saveSuggestionStates()
    }

    func addChain(_ commands: [String], from suggestion: Noticing.Suggestion? = nil) {
        if !chains.contains(commands) { chains.append(commands) }
        defaults.set(try? JSONEncoder().encode(chains), forKey: Self.chainsKey)
        if let suggestion { markApplied(suggestion) }
    }

    func removeChain(_ commands: [String]) {
        chains.removeAll { $0 == commands }
        defaults.set(try? JSONEncoder().encode(chains), forKey: Self.chainsKey)
        if let key = suggestionStates.keys.first(where: { $0 == "chain:" + commands.joined(separator: ">") }) {
            suggestionStates[key]?.appliedAt = nil
            saveSuggestionStates()
        }
    }

    func markApplied(_ suggestion: Noticing.Suggestion) {
        suggestionStates[suggestion.id, default: SuggestionState()].appliedAt = .now
        saveSuggestionStates()
    }

    private func saveSuggestionStates() {
        defaults.set(try? JSONEncoder().encode(suggestionStates), forKey: Self.suggestionsKey)
    }

    /// Chains this project can run: every command in it exists here (own or built in).
    func chains(for projectId: Int64) -> [[String]] {
        let names = Set((commandsByProject[projectId] ?? []).map(\.name))
        return chains.filter { $0.allSatisfy(names.contains) }
    }

    /// Types the first command; each next one follows the session's real end of turn (a Stop with no
    /// background work). A step that ends with a question pauses the chain until the user resumes it.
    func runChain(_ commands: [String], in sessionId: Int64) {
        guard let first = commands.first else { return }
        runningChains[sessionId] = (commands, 1, false)
        type("/\(first)\r", into: sessionId)
    }

    func resumeChain(_ sessionId: Int64) {
        guard let run = runningChains[sessionId] else { return }
        runningChains[sessionId]?.paused = false
        advanceChain(sessionId, run: (run.commands, run.next, false))
    }

    func stopChain(_ sessionId: Int64) { runningChains[sessionId] = nil }

    private func advanceChain(_ sessionId: Int64, run: (commands: [String], next: Int, paused: Bool)) {
        guard run.next < run.commands.count else {
            runningChains[sessionId] = nil
            chainRuns[run.commands.joined(separator: ">"), default: 0] += 1
            defaults.set(chainRuns, forKey: Self.chainRunsKey)
            return
        }
        runningChains[sessionId] = (run.commands, run.next + 1, false)
        type("/\(run.commands[run.next])\r", into: sessionId)
    }

    /// Called for every hook event of a session with a chain running.
    private func stepChain(_ payload: HookPayload, sessionId: Int64) {
        guard let run = runningChains[sessionId], !run.paused else { return }
        if payload.event == "StopFailure" { runningChains[sessionId] = nil; return }
        guard payload.event == "Stop", payload.backgroundTasks == 0 else { return }
        let reply = (payload.lastAssistantMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.hasSuffix("?") || reply.hasSuffix("？") {
            runningChains[sessionId]?.paused = true // Claude asked something: the user answers first
            return
        }
        advanceChain(sessionId, run: run)
    }

    /// A first draft of a personal skill for a request the user keeps typing — `claude -p`, only on click.
    func draftSkill(for phrase: String) async throws -> String {
        let text = (try? String(contentsOf: Automations.historyFile, encoding: .utf8)) ?? ""
        let examples = Noticing.entries(historyLines: text.split(separator: "\n"))
            .filter { Noticing.normalized($0.display) == phrase }.suffix(5).map(\.display)
        let prompt = """
            Write a Claude Code skill file (SKILL.md) for a request this user types again and again in Claude Code.
            Their words, most recent last:
            \(examples.map { "- " + $0 }.joined(separator: "\n"))

            Output only the file. Start with YAML frontmatter: `name` (short, lowercase, latin letters and hyphens), \
            `description` (one line: what it does and when to use it, in English). Then short, concrete instructions for \
            Claude in the user's language. Don't invent project details you can't see.
            """
        guard let login = loginEnvironment else { throw ClaudeHeadless.Failure(errorDescription: "claude isn't found in the login shell") }
        let draft = try await ClaudeHeadless.run(prompt, claude: login.claudePath, environment: login.environment)
        // A model may wrap the file in a code fence; the file is what's inside.
        return draft.replacingOccurrences(of: #"^```[a-z]*\n|\n```$"#, with: "", options: .regularExpression)
    }

    /// Saves a drafted skill as the user's own (~/.claude/skills/<name>/SKILL.md); never overwrites one.
    func saveSkill(named name: String, text: String, for suggestion: Noticing.Suggestion) throws -> URL {
        let slug = ClaudeLauncher.worktreeSlug(name)
        guard !slug.isEmpty else { throw ClaudeHeadless.Failure(errorDescription: "The name needs latin letters or digits") }
        let file = bridge.settingsURL.deletingLastPathComponent().appending(path: "skills/\(slug)/SKILL.md")
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw ClaudeHeadless.Failure(errorDescription: "You already have a skill called \(slug)")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        ChangeLog.record("New skill /\(slug)", file: file, backup: nil, backups: backupsDir)
        markApplied(suggestion)
        refreshProjects()
        return file
    }

    // MARK: Automations — the user's skills and commands, how they're used, their settings

    /// Built off the main thread: reads history.jsonl and asks git which project files are the team's.
    func automations() async -> [Automations.Item] {
        let projects = projects.map { (name: $0.name, path: $0.path) }
        let home = bridge.settingsURL.deletingLastPathComponent()
        return await Task.detached {
            let history = (try? String(contentsOf: Automations.historyFile, encoding: .utf8)) ?? ""
            let usage = Automations.usage(historyLines: history.split(separator: "\n"))
            var items: [String: Automations.Item] = [:]
            var seenFiles: Set<String> = []
            func add(_ command: SlashCommand, project: (name: String, path: String)?) {
                var item = items[command.name] ?? Automations.Item(
                    name: command.name, description: command.description, personalFiles: [], teamFiles: [],
                    owner: .builtIn, projects: [],
                    usage: usage[command.name] ?? Automations.Usage(weekly: Array(repeating: 0, count: Automations.weeks), lastUsed: nil))
                if let project, !item.projects.contains(project.name) { item.projects.append(project.name) }
                if let file = command.file, seenFiles.insert(file.path).inserted {
                    let isTeam = project.map { file.path.hasPrefix($0.path + "/") && GitService.isTracked(file.path, in: $0.path) } ?? false
                    if isTeam { item.teamFiles.append(file) } else { item.personalFiles.append(file) }
                    item.owner = !item.teamFiles.isEmpty ? .team : .personal
                    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                    item.effort = item.effort ?? Automations.frontmatterValue("effort", in: text)
                    item.model = item.model ?? Automations.frontmatterValue("model", in: text)
                }
                items[command.name] = item
            }
            if projects.isEmpty {
                for command in CommandCatalog.commands(projectPath: home.path) { add(command, project: nil) }
            }
            for project in projects {
                for command in CommandCatalog.commands(projectPath: project.path) {
                    let inProject = command.file.map { $0.path.hasPrefix(project.path + "/") } ?? false
                    add(command, project: inProject ? project : nil)
                }
            }
            return items.values.sorted { ($0.usage.total, $1.name) > ($1.usage.total, $0.name) }
        }.value
    }

    /// skillOverrides from ~/.claude/settings.json: "name-only", "user-invocable-only", "off"; absent = "on".
    func skillOverrides() -> [String: String] {
        ((try? bridge.readSettings())?["skillOverrides"] as? [String: String]) ?? [:]
    }

    /// Personal, in ~/.claude/settings.json — works for team skills too without touching the team's files.
    func setSkillOverride(_ name: String, to value: String) throws {
        try bridge.editSettings("\(name): \(value == "on" ? "listed normally" : value)") { settings in
            var overrides = settings["skillOverrides"] as? [String: Any] ?? [:]
            overrides[name] = value == "on" ? nil : value
            settings["skillOverrides"] = overrides.isEmpty ? nil : overrides
        }
    }

    /// effort / model in the frontmatter of every personal copy — Claude Code applies them when the skill runs.
    /// The team's copies (in git) stay as they are.
    func setFrontmatter(_ item: Automations.Item, _ key: String, to value: String?) throws {
        for file in item.personalFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            let backup = try ChangeLog.backup(file, folder: "skills", backups: backupsDir)
            try Automations.settingFrontmatter(key, to: value, in: text).write(to: file, atomically: true, encoding: .utf8)
            ChangeLog.record("/\(item.name): \(key) \(value ?? "default")", file: file, backup: backup, backups: backupsDir)
        }
    }

    /// What in the changelog touches this user: Meepo's own needs plus what ~/.claude/settings.json uses.
    func claudeNewsKeywords() -> [String] {
        let settings = (try? Data(contentsOf: bridge.settingsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return ClaudeChangelog.keywords(settings: settings)
    }

    func reload() {
        projects = (try? db.read { try Project.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll($0) }) ?? []
        sessions = (try? db.read { try Session.order(Column("createdAt")).fetchAll($0) }) ?? []
    }

    // MARK: Hook events

    var waitingCount: Int {
        sessions.filter { $0.status == .waitingInput || $0.status == .waitingPermission }.count
    }

    // MARK: Quitting without cutting agents off

    /// Sessions in the middle of a turn: quitting now would cut them off.
    var workingSessionIds: [Int64] {
        // Statuses reset at launch, so "thinking" means a live turn in this run — unless claude has since exited.
        sessions.filter { $0.status == .thinking && $0.id.map(exitedSessionIds.contains) == false }.compactMap(\.id)
    }

    /// Mid-turn when Meepo last went away; cleared by the session's next event or by Continue.
    private(set) var interruptedSessionIds: Set<Int64> = []
    /// Quit (or restart into an update) as soon as no agent is working.
    private(set) var quitWhenIdle = false
    /// Open Meepo again after quitting — RESTART into a downloaded update.
    var relaunchAfterQuit = false
    private var isQuitConfirmed = false
    /// How the app really quits (NSApp.terminate); tests leave it empty.
    var terminate: () -> Void = {}

    /// Called on every quit (⌘Q, menu bar, restart). True = quit now; false = a question is on screen.
    func shouldQuit() -> Bool {
        let working = workingSessionIds.count
        if isQuitConfirmed || working == 0 { return true }
        confirmation = PixelConfirmation(
            title: working == 1 ? "An agent is still working" : "\(working) agents are still working",
            message: "Quitting now stops them mid-turn. Their conversations come back when meepo opens (claude --resume), but the unfinished turn is lost.",
            action: "Quit now",
            alternative: ("Quit when they finish", { [weak self] in self?.quitWhenIdle = true }),
            onCancel: { [weak self] in self?.relaunchAfterQuit = false }
        ) { [weak self] in
            self?.isQuitConfirmed = true
            self?.terminate()
        }
        return false
    }

    func cancelQuitWhenIdle() {
        quitWhenIdle = false
        relaunchAfterQuit = false
    }

    /// Resumed sessions don't pick an interrupted turn up by themselves; this asks claude to.
    func continueInterrupted(_ sessionId: Int64) {
        interruptedSessionIds.remove(sessionId)
        type("continue\r", into: sessionId)
    }

    // MARK: Crash reports (local only)

    private static let crashesSeenKey = "crashesSeenAt"
    /// macOS's report of Meepo's last crash, if it's newer than the last one the user dismissed.
    private(set) var lastCrashReport: URL?

    private static func crashesSeen(_ defaults: UserDefaults) -> Date {
        if let seen = defaults.object(forKey: crashesSeenKey) as? Date { return seen }
        defaults.set(Date.now, forKey: crashesSeenKey) // first run: nothing from before counts
        return .now
    }

    func dismissCrashReport() {
        defaults.set(Date.now, forKey: Self.crashesSeenKey)
        lastCrashReport = nil
    }

    /// Applies a hook event to its session; returns what (if anything) the user should be told.
    @discardableResult
    func handleHookEvent(_ payload: HookPayload, sessionId: Int64) -> Attention? {
        interruptedSessionIds.remove(sessionId)
        defer {
            if quitWhenIdle, workingSessionIds.isEmpty {
                quitWhenIdle = false
                isQuitConfirmed = true
                terminate()
            }
        }
        guard var session = sessions.first(where: { $0.id == sessionId }) else { return nil }
        let old = session.status
        // `/clear` starts a new conversation in the same process; resume that one after a restart.
        if payload.event == "SessionStart" { session.claudeSessionId = payload.claudeSessionId }
        if let stage = nextStage(after: session.stage, for: payload) { session.stage = stage }
        let todos = payload.todoLines.map {
            AgentTodo(projectId: session.projectId, file: payload.toolTarget ?? "", line: $0, createdAt: .now)
        }
        // A Notification is a delayed echo (~6 s) of a prompt already reported by PermissionRequest;
        // it must not turn a question (waiting for input) into a permission request.
        let isEcho = payload.event == "Notification" && (old == .waitingInput || old == .waitingPermission)
        if let status = payload.status, !isEcho { session.status = status }
        session.lastActiveAt = .now
        var event = HookEvent(sessionId: sessionId, name: payload.event, summary: payload.summary,
                              isFailure: payload.isFailure, createdAt: .now)
        do {
            try db.write { db in
                try session.update(db)
                try event.insert(db)
                for var todo in todos { try todo.insert(db) }
            }
        } catch {
            return nil
        }
        reload()
        if sessionId == selectedSessionId { reloadEvents() }
        stepChain(payload, sessionId: sessionId)
        if payload.event == "Stop", payload.backgroundTasks == 0, relayingSessionIds.contains(sessionId) {
            finishRelay(sessionId, summary: payload.lastAssistantMessage)
            return nil
        }
        let attention = Attention.from(old, to: session.status)
        return payload.isQuestion && attention != nil ? .question : attention
    }

    private func reloadEvents() {
        guard let id = selectedSessionId else { selectedEvents = []; return }
        selectedEvents = (try? db.read {
            try HookEvent.filter(Column("sessionId") == id)
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(Self.feedLimit).fetchAll($0)
        }) ?? []
    }

    // MARK: Bridge

    func installBridge() {
        do {
            try bridge.install()
            try bridge.setNotifyGuard(true, projectPaths: projects.map(\.path))
            bridgeError = nil
        } catch {
            bridgeError = error.localizedDescription
        }
        isBridgeInstalled = bridge.isInstalled()
    }

    func uninstallBridge() {
        do {
            try bridge.setNotifyGuard(false, projectPaths: projects.map(\.path))
            try bridge.uninstall()
            bridgeError = nil
        } catch {
            bridgeError = error.localizedDescription
        }
        isBridgeInstalled = bridge.isInstalled()
    }

    /// While the bridge is installed: keep its script in sync with this Meepo version and
    /// the user's own Notification hooks quiet in Meepo sessions (no-op when already done).
    func refreshBridge() {
        guard isBridgeInstalled else { return }
        try? bridge.writeScript()
        if !bridge.isUpToDate() { _ = try? bridge.install() } // a newer Meepo subscribes to more events
        try? bridge.setNotifyGuard(true, projectPaths: projects.map(\.path))
    }

    // MARK: Usage (tokens, context)

    struct SessionUsage: Equatable {
        var tokensToday = 0
        /// Tokens in the window at the latest main-conversation response.
        var contextTokens = 0
        var model: String?
    }

    struct UsageTotals: Equatable {
        var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
        var total: Int { input + output + cacheWrite + cacheRead }
    }

    struct UsageStats {
        var total = UsageTotals()
        var byProject: [(name: String, totals: UsageTotals)] = []
        var byModel: [(name: String, totals: UsageTotals)] = []
    }

    static let defaultContextWindow = 200_000
    private static let contextWindowsKey = "contextWindows"

    private(set) var sessionUsage: [Int64: SessionUsage] = [:]
    private var isScanning = false

    /// Context window per model set by hand in Settings; other models get `nativeWindow`.
    var contextWindows: [String: Int] {
        didSet { defaults.set(try? JSONEncoder().encode(contextWindows), forKey: Self.contextWindowsKey) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    func contextWindow(for model: String?) -> Int {
        model.flatMap { contextWindows[$0] } ?? model.map(Self.nativeWindow) ?? Self.defaultContextWindow
    }

    /// Models whose window is 1M without asking — Claude Code's own model table (2.1.282).
    private static let millionTokenModels: Set = ["claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5",
                                                  "claude-sonnet-5", "claude-fable-5", "claude-fable-5-1",
                                                  "claude-mythos-5", "claude-mythos-5-1"]

    /// "claude-opus-5-5", "claude-opus-5-5-20260801" or "claude-sonnet-4-6[1m]" → the window Claude Code uses.
    static func nativeWindow(_ model: String) -> Int {
        if model.hasSuffix("[1m]") { return 1_000_000 }
        let bare = model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        return millionTokenModels.contains(bare) ? 1_000_000 : defaultContextWindow
    }

    // MARK: Live numbers from Claude Code's statusline (Meepo's sessions only)

    /// The latest statusline update per session: model, effort, context as Claude Code itself counts them.
    private(set) var liveStatus: [Int64: StatusLine] = [:]
    /// The plan's usage limits — account-wide, so the newest update from any session.
    private(set) var usageLimits: (fiveHour: StatusLine.Limit?, sevenDay: StatusLine.Limit?)?

    /// "Opus 5.5 · xhigh": what the session really runs, once Claude Code has said; else what Meepo started it with.
    func modelLine(of session: Session) -> String {
        let live = session.id.flatMap { liveStatus[$0] }
        let model = live?.modelName ?? session.model ?? "default model"
        let effort = live?.effort ?? session.effort
        return [model, effort].compactMap { $0 }.joined(separator: " · ")
    }

    func applyStatusLine(_ status: StatusLine, sessionId: Int64) {
        if liveStatus[sessionId] != status { liveStatus[sessionId] = status }
        if status.fiveHour != nil || status.sevenDay != nil,
           usageLimits?.fiveHour != status.fiveHour || usageLimits?.sevenDay != status.sevenDay {
            usageLimits = (status.fiveHour, status.sevenDay)
        }
    }

    /// 0…1 (can exceed 1 if the window setting is too small); nil before the first response.
    func contextFraction(for sessionId: Int64) -> Double? {
        if let percent = liveStatus[sessionId]?.contextPercent { return percent / 100 } // Claude Code's own count
        guard let usage = sessionUsage[sessionId], usage.contextTokens > 0 else { return nil }
        return Double(usage.contextTokens) / Double(contextWindow(for: usage.model))
    }

    /// Reads new JSONL lines in the background, then refreshes per-session numbers.
    func refreshUsage() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let (db, root) = (self.db, usageRoot)
        _ = try? await Task.detached { try UsageScanner.scan(root: root, into: db) }.value
        reloadUsage()
        reloadEvents() // the scan may have found tool calls blocked by the user's hooks
        refreshProjects()
    }

    // MARK: Updates (like Claude Code, 2026-09-25)

    enum UpdateState: Equatable {
        case idle, checking, upToDate
        case downloading(String)
        /// Downloaded and verified; installs when Meepo quits.
        case ready(version: String, notes: String)
        /// Newer version out, but this copy can't replace itself: the user updates (brew / download).
        case manual(version: String, page: String)
    }

    private static let autoUpdateKey = "autoUpdate"
    private static let channelKey = "updateChannel"

    private(set) var updateState = UpdateState.idle
    private var stagedUpdate: URL?

    var autoUpdate: Bool {
        didSet { defaults.set(autoUpdate, forKey: Self.autoUpdateKey) }
    }

    /// Betas by default while Meepo itself is a beta, stable afterwards.
    var updateChannel: Updater.Channel {
        didSet { defaults.set(updateChannel.rawValue, forKey: Self.channelKey) }
    }

    /// At launch, every few hours, and on `meepo update`: find, download and verify a newer release.
    func checkForUpdates(userInitiated: Bool = false) async {
        guard let current = Updater.currentVersion else {
            if userInitiated { notice("NO UPDATES FOR THIS BUILD", "It isn't a release build (built from source).") }
            return
        }
        guard autoUpdate || userInitiated else { return }
        // One already downloaded: still look for a newer one (a day of releases shouldn't stop at the first).
        var baseline = current
        if case let .ready(staged, _) = updateState, let version = Updater.Version(staged) { baseline = version }
        let wasReady = updateState
        updateState = .checking
        lastUpdateCheck = .now
        do {
            let releases = try await Updater.fetchReleases()
            guard let release = Updater.pick(releases, channel: updateChannel, current: baseline), let version = release.version else {
                if case .ready = wasReady { updateState = wasReady; return }
                updateState = .upToDate
                if userInitiated { notice("MEEPO IS UP TO DATE", "\(current) is the newest on the \(updateChannel.rawValue) channel.") }
                return
            }
            let target = Bundle.main.bundleURL
            guard Updater.canReplace(target) else {
                updateState = .manual(version: version.text, page: release.html_url)
                return
            }
            updateState = .downloading(version.text)
            let app = try await Updater.download(release)
            let own = await Task.detached { Updater.signature(of: target) }.value
            guard let team = own.team, let bundleID = own.identifier else { throw Updater.Failure("this copy of meepo isn't signed") }
            if let problem = await Task.detached(operation: { Updater.verify(app, team: team, bundleID: bundleID) }).value {
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
                throw Updater.Failure("\(version) was rejected: \(problem)")
            }
            stagedUpdate = app
            updateState = .ready(version: version.text, notes: release.body ?? "")
        } catch {
            if case .ready = wasReady { updateState = wasReady } else { updateState = .idle }
            if userInitiated { notice("UPDATE FAILED", error.localizedDescription) }
        }
    }

    private(set) var lastUpdateCheck: Date?

    /// When Meepo comes to the front: check again if the last look was over an hour ago.
    func checkForUpdatesIfStale() async {
        guard lastUpdateCheck.map({ Date.now.timeIntervalSince($0) > 3600 }) ?? true else { return }
        await checkForUpdates()
    }

    /// At quit (and RESTART NOW): puts the verified download in place of this app. True when it did.
    @discardableResult
    func installStagedUpdate() -> Bool {
        guard let staged = stagedUpdate else { return false }
        do {
            try Updater.install(staged, over: Bundle.main.bundleURL,
                                backup: Updater.stagingDir.appending(path: "previous/Meepo.app"))
            stagedUpdate = nil
            return true
        } catch {
            bridgeError = "Update not installed: \(error.localizedDescription)"
            return false
        }
    }

    private func notice(_ title: String, _ message: String) {
        confirmation = PixelConfirmation(title: title, message: message, action: "OK", cancel: nil, isDestructive: false) {}
    }

    private var widgetSnapshot = WidgetSnapshot()

    /// Hands the desktop widget its numbers; reloads it only when they change (WidgetKit budgets reloads).
    func publishWidgetSnapshot() {
        let next = WidgetSnapshot(tokensToday: usageStats(since: Calendar.current.startOfDay(for: .now)).total.total,
                                  activeSessions: runningSessionIds.count, waitingSessions: waitingCount, updatedAt: .now)
        var previous = widgetSnapshot
        previous.updatedAt = next.updatedAt
        // Unchanged numbers still refresh the file hourly, so the widget can tell Meepo is alive.
        guard previous != next || widgetSnapshot.updatedAt < .now.addingTimeInterval(-1800) else { return }
        widgetSnapshot = next
        try? next.write()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func reloadUsage() {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        var result: [Int64: SessionUsage] = [:]
        try? db.read { db in
            for session in sessions {
                guard let id = session.id else { continue }
                let today = try Int.fetchOne(db, sql: """
                    SELECT SUM(inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens)
                    FROM usageRecord WHERE claudeSessionId = ? AND createdAt >= ?
                    """, arguments: [session.claudeSessionId, startOfDay]) ?? 0
                let last = try UsageRecord
                    .filter(Column("claudeSessionId") == session.claudeSessionId && Column("isSidechain") == false)
                    .order(Column("createdAt").desc)
                    .fetchOne(db)
                result[id] = SessionUsage(tokensToday: today, contextTokens: last?.contextTokens ?? 0, model: last?.model)
            }
        }
        sessionUsage = result
    }

    /// Everything Claude Code spent since `start`, all sessions on this Mac; projects outside Meepo go to "Other".
    func usageStats(since start: Date) -> UsageStats {
        let sums = "SUM(inputTokens) AS i, SUM(outputTokens) AS o, SUM(cacheCreationTokens) AS w, SUM(cacheReadTokens) AS r"
        func totals(_ row: Row) -> UsageTotals {
            UsageTotals(input: row["i"] ?? 0, output: row["o"] ?? 0, cacheWrite: row["w"] ?? 0, cacheRead: row["r"] ?? 0)
        }
        func add(_ a: UsageTotals, _ b: UsageTotals) -> UsageTotals {
            UsageTotals(input: a.input + b.input, output: a.output + b.output,
                        cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
        }
        var stats = UsageStats()
        try? db.read { db in
            let byModel = try Row.fetchAll(db, sql: "SELECT model, \(sums) FROM usageRecord WHERE createdAt >= ? GROUP BY model",
                                           arguments: [start])
            stats.byModel = byModel.map { (name: $0["model"] as String, totals: totals($0)) }
            var byProject: [String: UsageTotals] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT cwd, \(sums) FROM usageRecord WHERE createdAt >= ? GROUP BY cwd",
                                        arguments: [start]) {
                let cwd: String = row["cwd"]
                let name = projects.first { cwd == $0.path || cwd.hasPrefix($0.path + "/") }?.name ?? "Other"
                byProject[name] = add(byProject[name] ?? UsageTotals(), totals(row))
            }
            stats.byProject = byProject.map { (name: $0.key, totals: $0.value) }
        }
        stats.byModel.sort { $0.totals.total > $1.totals.total }
        stats.byProject.sort { $0.totals.total > $1.totals.total }
        stats.total = stats.byModel.reduce(UsageTotals()) { add($0, $1.totals) }
        return stats
    }

    /// Models seen in the last 30 days, for the context window settings.
    /// "<synthetic>" is Claude Code's marker for messages that never hit the API, not a model.
    func recentModels() -> [String] {
        (try? db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT model FROM usageRecord WHERE createdAt >= ? AND model NOT LIKE '<%' ORDER BY model",
                                arguments: [Date.now.addingTimeInterval(-30 * 24 * 3600)])
        }) ?? []
    }

    /// Aliases `claude --model` documents (latest of each family), then full names the user has actually used.
    static let modelAliases = ["fable", "opus", "sonnet", "haiku"]

    /// ("" = Claude Code's default, value for --model, title).
    func modelChoices() -> [(value: String, title: String)] {
        [("", "Default")] + Self.modelAliases.map { ($0, $0.capitalized) } + recentModels().map { ($0, $0) }
    }

    // MARK: Stages and relay (SPEC module 4)

    private static let stagesKey = "stages"
    private static let relayThresholdKey = "relayThreshold"

    /// The user's workflow, set once for all projects.
    var stages: [Stage] {
        didSet { defaults.set(try? JSONEncoder().encode(stages), forKey: Self.stagesKey) }
    }

    // MARK: Window layout (Meepo 2.0, layout "c")

    private static let shellKey = "shellLayout"
    private static let shellPresetKey = "shellPreset"
    private static let customShellKey = "shellCustom"

    var shellPreset: ShellLayout.Preset {
        didSet { defaults.set(shellPreset.rawValue, forKey: Self.shellPresetKey) }
    }

    /// What the window shows now; any change by hand is kept as the Custom preset.
    private(set) var shell: ShellLayout {
        didSet { defaults.set(try? JSONEncoder().encode(shell), forKey: Self.shellKey) }
    }

    /// The Home tab (Deck/Timeline) instead of a session; picking a session leaves it.
    var isHomeShown = false

    func applyPreset(_ preset: ShellLayout.Preset) {
        shellPreset = preset
        shell = ShellLayout.preset(preset) ?? Self.load(ShellLayout.self, Self.customShellKey, from: defaults) ?? shell
    }

    /// Moves, hides or opens panels by hand: the result becomes (and is saved as) Custom.
    func editShell(_ change: (inout ShellLayout) -> Void) {
        var layout = shell
        change(&layout)
        guard layout != shell else { return }
        shell = layout
        shellPreset = .custom
        defaults.set(try? JSONEncoder().encode(layout), forKey: Self.customShellKey)
    }

    /// How many terminals the center actually fits right now (a narrow window shows fewer than the split).
    var fittingPanes: Int?

    /// Where the row of terminals on screen starts. Picking a session already on screen keeps it (clicking the
    /// second terminal just focuses it — the tester found panes swapping places confusing); picking one that
    /// isn't moves the row to start there.
    private var paneAnchor: Int64?

    /// Sessions whose terminals are on screen, in the sidebar's order, the selected one among them.
    var visibleSessionIds: [Int64] {
        guard !isHomeShown, let selected = selectedSessionId else { return [] }
        let count = min(shell.split, fittingPanes ?? shell.split)
        let window = paneWindow(from: paneAnchor ?? selected, count: count)
        return window.contains(selected) ? window : paneWindow(from: selected, count: count)
    }

    private func paneWindow(from anchor: Int64, count: Int) -> [Int64] {
        let ids = orderedSessions.compactMap(\.id)
        guard let start = ids.firstIndex(of: anchor) else { return Array(ids.prefix(count)) }
        return Array((ids[start...] + ids[..<start]).prefix(count))
    }

    /// The repos the selected session works in (its folder, the repos inside it, "Also work in" folders).
    private(set) var sessionRepos: [Repo] = []
    /// Git state per repo path, shared by Explorer and Source Control.
    private(set) var sourceControls: [String: GitPanel.SourceControl] = [:]

    func refreshSourceControls(for session: Session) async {
        guard let folder = workdir(of: session) else { sessionRepos = []; return }
        let extra = session.extraDirs ?? []
        let repos = await Task.detached {
            Repos.find(in: folder) + extra.flatMap { dir in Repos.find(in: dir).map { Repo(name: $0.name, path: $0.path, isLinked: true) } }
        }.value
        if repos != sessionRepos { sessionRepos = repos }
        for repo in repos { await refreshSourceControl(repo.path) }
    }

    func refreshSourceControl(_ path: String) async {
        let result = await Task.detached { GitPanel.sourceControl(in: path) }.value
        if sourceControls[path] != result { sourceControls[path] = result }
    }

    /// Changes of every repo under `root`, with paths relative to `root` — for the Explorer's colors.
    func changes(under root: String) -> [GitPanel.FileChange] {
        sessionRepos.filter { $0.path == root || $0.path.hasPrefix(root + "/") }.flatMap { repo -> [GitPanel.FileChange] in
            let prefix = repo.path == root ? "" : String(repo.path.dropFirst(root.count + 1)) + "/"
            return (sourceControls[repo.path]?.changes ?? []).map { change in
                var moved = GitPanel.FileChange(status: change.status, path: prefix + change.path, added: change.added, removed: change.removed)
                moved.isUncommitted = change.isUncommitted
                moved.oldPath = change.oldPath.map { prefix + $0 }
                return moved
            }
        }
    }

    /// Hook events of every session since `date`, oldest first — the Home timeline.
    func events(since date: Date) -> [HookEvent] {
        (try? db.read {
            try HookEvent.filter(Column("createdAt") >= date).order(Column("createdAt"), Column("id")).fetchAll($0)
        }) ?? []
    }

    private static let remoteControlKey = "remoteControl"
    private static let shotHotKeyKey = "screenshotHotKey"
    private static let libraryKey = "libraryFolder"

    /// Where shared practices live (SPEC module 11); default: the user's global ~/.claude.
    var libraryFolder: String {
        didSet { defaults.set(libraryFolder, forKey: Self.libraryKey) }
    }

    var libraryURL: URL { Library.resolve(URL(filePath: libraryFolder)) }

    /// Global screenshot hotkey (a `GlobalHotKey.combos` title); "" = off.
    var screenshotHotKey: String {
        didSet { defaults.set(screenshotHotKey, forKey: Self.shotHotKeyKey) }
    }

    /// Start sessions with Claude Code's Remote Control (phone app / claude.ai). Off by default:
    /// it needs a claude.ai login and shares the session with the user's Claude account.
    var remoteControlForNewSessions: Bool {
        didSet { defaults.set(remoteControlForNewSessions, forKey: Self.remoteControlKey) }
    }

    /// Context fill at which a session is marked "time to sync" and offers a relay.
    var relayThreshold: Double {
        didSet { defaults.set(relayThreshold, forKey: Self.relayThresholdKey) }
    }

    private(set) var commandsByProject: [Int64: [SlashCommand]] = [:]
    private(set) var dirtyProjectIds: Set<Int64> = []
    private(set) var relayingSessionIds: Set<Int64> = []

    /// Stages the project can run: command-less ones (code) and those whose command exists there.
    func stages(for projectId: Int64) -> [Stage] {
        stages.filter { $0.command == nil || command(for: $0, in: projectId) != nil }
    }

    /// What a stage runs in this project: its own command (the project's or ~/.claude's, which also wins over
    /// a built-in of the same name), else the Claude Code built-in that does the job; nil = nothing does.
    func command(for stage: Stage, in projectId: Int64) -> String? {
        guard let command = stage.command else { return nil }
        return CommandCatalog.resolve(command, available: Set((commandsByProject[projectId] ?? []).map(\.name)))
    }

    /// The user's own file for a stage command shadows Claude Code's built-in of the same name (e.g. /plan:
    /// the built-in forbids edits, a custom one may not).
    func shadowsBuiltIn(_ stage: Stage, in projectId: Int64) -> Bool {
        guard let command = stage.command, CommandCatalog.builtIns.contains(where: { $0.name == command }) else { return false }
        return (commandsByProject[projectId] ?? []).first { $0.name == command }?.description
            != CommandCatalog.builtIns.first { $0.name == command }?.description
    }

    /// A slash command enters its stage; a plain prompt right after a stage moves on to a following
    /// command-less stage (plan → code).
    func nextStage(after current: String?, for payload: HookPayload) -> String? {
        if payload.event == "UserPromptExpansion", let command = payload.commandName {
            return stages.first { $0.command == command || CommandCatalog.standIns[$0.command ?? ""] == command }?.name
        }
        guard payload.event == "UserPromptSubmit", !(payload.prompt ?? "").hasPrefix("/"),
              let index = stages.firstIndex(where: { $0.name == current }),
              index + 1 < stages.count, stages[index + 1].command == nil else { return nil }
        return stages[index + 1].name
    }

    /// Types text into a session's terminal ("\r" = Enter).
    func type(_ text: String, into sessionId: Int64) {
        terminals.send(text, to: sessionId)
    }

    /// Code was edited after the last QA stage ran in this session (reminder before ship).
    func codeChangedSinceQA(_ sessionId: Int64) -> Bool {
        let stage = stages.first { $0.name == "qa" }
        let own = stage?.command ?? "qa"
        let qa = [own, CommandCatalog.standIns[own]].compactMap { $0 }
        return (try? db.read { db in
            let lastEdit = try Date.fetchOne(db, sql: """
                SELECT MAX(createdAt) FROM hookEvent WHERE sessionId = ? AND name = 'PostToolUse'
                AND (summary LIKE 'Edit:%' OR summary LIKE 'Write:%' OR summary LIKE 'MultiEdit:%' OR summary LIKE 'NotebookEdit:%')
                """, arguments: [sessionId])
            let lastQA = try Date.fetchOne(db, sql: """
                SELECT MAX(createdAt) FROM hookEvent WHERE sessionId = ? AND name = 'UserPromptExpansion'
                AND (summary LIKE ? OR summary LIKE ?)
                """, arguments: [sessionId, "/\(qa[0])%", "/\(qa.last!)%"])
            guard let lastEdit else { return false }
            return lastEdit > (lastQA ?? .distantPast)
        }) ?? false
    }

    /// The plan is ready when the plan stage's reply is in and the session waits for the user.
    func canStartImplementation(_ session: Session) -> Bool {
        session.stage == stages.first(where: { $0.command == "plan" })?.name && session.status == .waitingInput
    }

    /// Plan → code: a fresh session on the code stage's model, with the plan as its first message.
    /// `notes`: the user's answers to the plan's open questions, and any extra instructions.
    func startImplementation(from sessionId: Int64, notes: String = "") throws {
        guard let session = sessions.first(where: { $0.id == sessionId }),
              let plan = latestReply(of: sessionId) else { return }
        let code = stages.first { $0.command == nil }
        let decisions = notes.isEmpty ? "" : "\n\nMy decisions and notes (they override the plan where they differ):\n\(notes)"
        try successor(of: session, model: code?.model ?? session.model, effort: code?.effort, stage: code?.name,
                      prompt: "Implement the plan below, prepared in a previous session.\n\n\(plan)\(decisions)",
                      keepsPorts: false)
    }

    /// Relay: `/sync` (or a handoff request) in the old session; its reply seeds a fresh session in the
    /// same project, and the old one closes (SPEC module 4 "эстафета"). Finishes on that reply's Stop event.
    func relay(_ sessionId: Int64) {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        relayingSessionIds.insert(sessionId)
        let sync = stages.first { $0.name == "sync" }?.command
        if let sync, (commandsByProject[session.projectId] ?? []).contains(where: { $0.name == sync }) {
            type("/\(sync)\r", into: sessionId)
        } else {
            type("Summarize for a fresh session taking over: the task, what is done, what is next, key files and decisions.\r",
                 into: sessionId)
        }
    }

    private func finishRelay(_ sessionId: Int64, summary: String?) {
        relayingSessionIds.remove(sessionId)
        guard let old = sessions.first(where: { $0.id == sessionId }) else { return }
        let handoff = summary.map { "\n\nHandoff from the previous session:\n\n\($0)" } ?? ""
        do {
            let fresh = try successor(of: old, model: old.model, effort: old.effort, stage: old.stage,
                                      prompt: "Continue the task of the previous session (its context was full).\(handoff)",
                                      keepsPorts: true)
            closeSession(sessionId)
            selectedSessionId = fresh
        } catch {
            bridgeError = error.localizedDescription
        }
    }

    private func latestReply(of sessionId: Int64) -> String? {
        try? db.read { db in
            try String.fetchOne(db, sql: """
                SELECT summary FROM hookEvent WHERE sessionId = ? AND name = 'Stop' ORDER BY createdAt DESC, id DESC LIMIT 1
                """, arguments: [sessionId])
        }
    }

    /// Where a missing command could be copied from: other Meepo projects that have it as a file.
    func commandSources(_ command: String, excluding projectId: Int64) -> [Project] {
        let relative = ".claude/commands/\(command.replacingOccurrences(of: ":", with: "/")).md"
        return projects.filter { project in
            project.id != projectId && FileManager.default.fileExists(atPath: URL(filePath: project.path).appending(path: relative).path)
        }
    }

    /// Backups and the change log (SPEC §8); a temp folder in tests.
    var backupsDir: URL { bridge.meepoHome.appending(path: "backups") }

    /// Copies a command file into one project, or into `~/.claude/commands` for every project.
    /// Never overwrites: an existing file there wins. The user picks both source and target.
    func copyCommand(_ command: String, from source: Project, toProject target: Project?,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let relative = "commands/\(command.replacingOccurrences(of: ":", with: "/")).md"
        let from = URL(filePath: source.path).appending(path: ".claude/\(relative)")
        let to = (target.map { URL(filePath: $0.path).appending(path: ".claude") } ?? home.appending(path: ".claude"))
            .appending(path: relative)
        do {
            guard !FileManager.default.fileExists(atPath: to.path) else { return }
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: from, to: to)
            ChangeLog.record("Copy /\(command) from \(source.name)", file: to, backup: nil, backups: backupsDir)
        } catch {
            bridgeError = error.localizedDescription
        }
        refreshProjects()
    }

    // MARK: CI guard (SPEC module 9)

    private static let autofixKey = "ciAutofixProjects"
    private static let fixAttemptsKey = "ciFixAttempts"

    /// EXPLAIN in the inspector: changes from `from` to `to` (nil = files on disk) in plain words, by a headless claude.
    func explainChanges(in path: String, from: String, to: String?, whose: String, newFiles: [String]) async throws -> String {
        guard let login = loginEnvironment else { throw ClaudeHeadless.Failure(errorDescription: "claude isn't found in the login shell") }
        let diff = await Task.detached { GitPanel.fullDiff(from: from, to: to, in: path) }.value
        let prompt = GitPanel.explainPrompt(diff: diff, newFiles: newFiles, whose: whose, language: GitPanel.userLanguage)
        return try await ClaudeHeadless.run(prompt, claude: login.claudePath, environment: login.environment)
    }

    // MARK: Auto-sync with teammates (2026-09-24)

    /// Per Meepo session: what to tell the agent on its next prompt about teammates' commits.
    private(set) var teammateNotes: [Int64: String] = [:]
    /// Upstream tip already reported per folder, so the same commits aren't announced twice.
    private var notedUpstream: [String: String] = [:]
    /// Folders waiting for a clean tree to pull.
    private(set) var pendingPulls: Set<String> = []

    /// Fetches every running session's folder; teammates' new commits are pulled with --rebase when the tree is
    /// clean and the agent is between turns, and the agent hears about them on its next prompt. Never pushes.
    /// `only`: the sessions to sync (tests); by default the running ones.
    func autoSync(only: [Session]? = nil) async {
        let live = only ?? sessions.filter { runningSessionIds.contains($0.id ?? -1) }
        let byFolder = Dictionary(grouping: live) { workdir(of: $0) ?? "" }
        for (path, folderSessions) in byFolder where !path.isEmpty {
            let fetched = await Task.detached { () -> (status: GitPanel.Snapshot, incoming: (commits: [String], files: [String]), tip: String?) in
                GitPanel.fetch(in: path)
                let status = GitPanel.snapshot(in: path)
                guard status.upstream != nil, status.behind > 0 else { return (status, ([], []), nil) }
                return (status, GitPanel.incoming(in: path), GitService.output(["rev-parse", "@{u}"], in: path))
            }.value
            guard let tip = fetched.tip, let upstream = fetched.status.upstream else {
                pendingPulls.remove(path)
                continue
            }
            let idle = folderSessions.allSatisfy { $0.status == .idle || $0.status == .waitingInput }
            var pulled = false
            if fetched.status.changes.isEmpty && idle {
                if let error = await Task.detached(operation: { GitPanel.pullRebase(in: path) }).value {
                    onCINotice?("Pull stopped", "\(URL(filePath: path).lastPathComponent): \(error.split(separator: "\n").first ?? "") — the folder is as it was")
                } else {
                    pulled = true
                    pendingPulls.remove(path)
                }
            } else {
                pendingPulls.insert(path)
            }
            // Tell the agents once per new upstream tip, and again when the pull finally happened.
            let key = "\(tip)#\(pulled)"
            guard notedUpstream[path] != key else { continue }
            notedUpstream[path] = key
            let note = GitPanel.teammateNote(commits: fetched.incoming.commits, files: fetched.incoming.files,
                                             upstream: upstream, pulled: pulled)
            for session in folderSessions { if let id = session.id { teammateNotes[id] = note } }
        }
    }

    /// The bridge's reply to a hook: the teammates note, handed over once, on the session's next prompt.
    func hookReply(sessionId: Int64, body: Data) -> String? {
        guard HookPayload(json: body)?.event == "UserPromptSubmit" else { return nil }
        return teammateNotes.removeValue(forKey: sessionId)
    }

    /// A question or notice shown over the main window (pixel style, not a system dialog).
    var confirmation: PixelConfirmation?

    /// Latest run per workflow + branch, per project.
    private(set) var ciRuns: [Int64: [CIRun]] = [:]
    /// Default branch's latest commit through CI → build → deploy, per project.
    private(set) var pipelines: [Int64: Pipeline] = [:]
    /// Projects whose failed CI Meepo reruns and fixes on its own; the rest only get notified.
    var autofixProjectIds: Set<Int64> = [] {
        didSet { defaults.set(Array(autofixProjectIds), forKey: Self.autofixKey) }
    }
    private var fixAttempts: [String: Int] = [:] {
        didSet { defaults.set(fixAttempts, forKey: Self.fixAttemptsKey) }
    }
    /// Run attempts already seen as failed, so each failure is handled once.
    private var handledFailures: Set<String> = []
    private var isCIPrimed = false
    /// Injected in tests; otherwise GitHub Actions via `gh` and GitLab CI via `glab`, whichever is installed.
    var ciProviders: [any CIProvider] = []
    /// (title, body) for a macOS notification; set by the app.
    var onCINotice: ((String, String) -> Void)?

    /// A tool from the user's login shell PATH (GUI apps don't see Homebrew's bin).
    func toolPath(_ name: String) -> String? {
        let path = loginEnvironment?.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return path.split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func ciProvider(for project: Project) -> (any CIProvider)? {
        ciProviders.first { $0.handles(project) }
    }

    /// Polls CI and acts on new failures. The first pass after launch only records history.
    func refreshCI() async {
        if ciProviders.isEmpty {
            ciProviders = [toolPath("gh").map { GitHubActions(gh: $0) }, toolPath("glab").map { GitLabCI(glab: $0) }].compactMap { $0 }
        }
        for project in projects {
            guard let projectId = project.id, let provider = ciProvider(for: project) else { continue }
            let runs = await provider.runs(in: project.path).sorted { $0.createdAt > $1.createdAt }
            pipelines[projectId] = await provider.pipeline(runs: runs, in: project.path)
            var latest: [String: CIRun] = [:]
            for run in runs where latest[run.key] == nil { latest[run.key] = run }
            ciRuns[projectId] = latest.values.sorted { $0.createdAt > $1.createdAt }
            for run in latest.values {
                let attemptsKey = "\(projectId)|\(run.key)"
                if run.succeeded { fixAttempts[attemptsKey] = nil }
                guard run.failed, handledFailures.insert("\(run.id)#\(run.attempt)").inserted, isCIPrimed else { continue }
                let label = "\(project.name) · \(run.headBranch)"
                switch CIGuard.action(for: run, fixAttempts: fixAttempts[attemptsKey] ?? 0,
                                      autofix: autofixProjectIds.contains(projectId)) {
                case .rerun:
                    _ = await provider.rerunFailed(run, in: project.path)
                    onCINotice?("CI failed — rerunning once", "\(label): \(run.workflowName)")
                case .fix:
                    await startCIFix(run, in: project, provider: provider)
                case .giveUp:
                    onCINotice?("CI still failing — gave up", "\(label): \(run.workflowName) after \(CIGuard.maxFixAttempts) fixes")
                case .reportInfra:
                    onCINotice?("CI didn't run", "\(label): \(run.failureReason ?? "") — not a code failure")
                case .reportDeploy:
                    onCINotice?("Deploy failed", "\(label): \(run.workflowName) — not fixed automatically")
                case .none:
                    onCINotice?("CI failed", "\(label): \(run.workflowName) — FIX in the CI tab")
                }
            }
        }
        await refreshRepoCI()
        isCIPrimed = true
    }

    /// CI of repos that aren't Meepo projects themselves: the ones inside a plain project folder and "Also work
    /// in" folders. Shown next to the project's CI; no autofix or notifications for them.
    private(set) var repoCI: [String: (runs: [CIRun], pipeline: Pipeline?)] = [:]

    /// Repos inside a project folder that isn't one itself (charge-ev → ocpi, ocpp2.0, …), by project path.
    private(set) var nestedRepos: [String: [Repo]] = [:]

    private func refreshRepoCI() async {
        let projectPaths = Set(projects.map(\.path))
        let paths = projects.map(\.path)
        let nested = await Task.detached {
            Dictionary(uniqueKeysWithValues: paths.map { path in (path, Repos.find(in: path).filter { $0.path != path }) })
        }.value
        if nested != nestedRepos { nestedRepos = nested }
        let folders = projects.map(\.path) + sessions.flatMap { $0.extraDirs ?? [] }
        let repos = await Task.detached {
            Set(folders.flatMap(Repos.find)).filter { !projectPaths.contains($0.path) }
                .map { (repo: $0, remote: GitService.remoteURL(in: $0.path)) }
        }.value
        for (repo, remote) in repos {
            let stand = Project(name: repo.name, path: repo.path, remote: remote)
            guard let provider = ciProvider(for: stand) else { continue }
            let runs = await provider.runs(in: repo.path).sorted { $0.createdAt > $1.createdAt }
            var latest: [String: CIRun] = [:]
            for run in runs where latest[run.key] == nil { latest[run.key] = run }
            repoCI[repo.path] = (latest.values.sorted { $0.createdAt > $1.createdAt }, await provider.pipeline(runs: runs, in: repo.path))
        }
    }

    /// A manual step (deploy) of a repo that isn't a project — on click only, like the project's own.
    func startRepoPipelineStep(_ step: Pipeline.Step, in repo: Repo) async {
        let stand = Project(name: repo.name, path: repo.path, remote: GitService.remoteURL(in: repo.path))
        guard let pipeline = repoCI[repo.path]?.pipeline, let provider = ciProvider(for: stand) else { return }
        if let error = await provider.start(step, of: pipeline, in: repo.path) { bridgeError = error }
        else { onCINotice?("\(step.name) started", "\(repo.name) · \(pipeline.branch) @ \(pipeline.sha.prefix(7))") }
        await refreshCI()
    }

    /// Fix session in its own worktree with the failed step's log and guardrails in its first prompt.
    func startCIFix(_ run: CIRun, in project: Project, provider: (any CIProvider)? = nil) async {
        guard let provider = provider ?? ciProvider(for: project), let projectId = project.id else { return }
        let log = await provider.failedLog(run, in: project.path)
        fixAttempts["\(projectId)|\(run.key)", default: 0] += 1
        let name = "ci-fix-\(ClaudeLauncher.worktreeSlug(run.headBranch))-\(run.databaseId % 100_000)"
        do {
            try createSession(projectId: projectId, model: nil, prompt: CIGuard.fixPrompt(run, log: log, reviewRequest: provider.reviewRequest), worktree: name)
            onCINotice?("Fixing CI", "\(project.name) · \(run.headBranch): \(run.workflowName) — new session \(name)")
        } catch {
            bridgeError = error.localizedDescription
        }
    }

    /// Starts a manual pipeline step (deploy) — only ever on the user's click, never automatically.
    func startPipelineStep(_ step: Pipeline.Step, in project: Project) async {
        guard let projectId = project.id, let pipeline = pipelines[projectId], let provider = ciProvider(for: project) else { return }
        if let error = await provider.start(step, of: pipeline, in: project.path) {
            bridgeError = error
        } else {
            onCINotice?("\(step.name) started", "\(project.name) · \(pipeline.branch) @ \(pipeline.sha.prefix(7))")
        }
        await refreshCI()
    }

    /// Worst CI state on the session's branch: failed, running, passed; nil when CI knows nothing about it.
    func ciState(for session: Session) -> CIRun? {
        let runs = (ciRuns[session.projectId] ?? []).filter { $0.headBranch == session.branch }
        return runs.first(where: \.failed) ?? runs.first(where: \.isRunning) ?? runs.first(where: \.succeeded)
    }

    // MARK: Release notes (SPEC module 12)

    private(set) var releaseNotes: [ReleaseNote] = []
    /// Projects whose note `claude -p` is writing right now.
    private(set) var writingNotes: Set<Int64> = []

    func reloadReleaseNotes() {
        releaseNotes = (try? db.read { try ReleaseNote.order(Column("createdAt").desc).fetchAll($0) }) ?? []
    }

    /// Drafts a note about the commits since the project's last note, in the style of the user's samples.
    func writeReleaseNote(for project: Project) async {
        guard let projectId = project.id, !writingNotes.contains(projectId) else { return }
        guard let login = loginEnvironment else { bridgeError = "claude isn't found in the login shell"; return }
        let last = releaseNotes.first { $0.projectId == projectId }
        guard let head = GitService.headCommit(in: project.path),
              let commits = ReleaseNotes.commits(after: last?.sha, in: project.path) else {
            bridgeError = "No new commits in \(project.name) since the last note"
            return
        }
        let style = (try? String(contentsOf: ReleaseNotes.styleURL, encoding: .utf8)) ?? ""
        let prompt = ReleaseNotes.prompt(project: project.name, commits: commits,
                                         shipReport: lastShipReport(projectId, after: last?.createdAt), style: style)
        writingNotes.insert(projectId)
        defer { writingNotes.remove(projectId) }
        do {
            let text = try await ClaudeHeadless.run(prompt, claude: login.claudePath, environment: login.environment)
            let note = ReleaseNote(projectId: projectId, sha: head, text: text)
            _ = try await db.write { try note.inserted($0) }
            reloadReleaseNotes()
        } catch {
            bridgeError = error.localizedDescription
        }
    }

    func updateReleaseNote(_ note: ReleaseNote) {
        try? db.write { try note.update($0) }
        reloadReleaseNotes()
    }

    func deleteReleaseNote(_ id: Int64) {
        _ = try? db.write { try ReleaseNote.deleteOne($0, id: id) }
        reloadReleaseNotes()
    }

    /// What Claude answered to the project's latest ship command (the first Stop after it), if newer than `date`.
    func lastShipReport(_ projectId: Int64, after date: Date?) -> String? {
        let ship = stages.first { $0.name == "ship" }?.command ?? "ship"
        return try? db.read { db in
            try String.fetchOne(db, sql: """
                SELECT e.summary FROM hookEvent e JOIN session s ON s.id = e.sessionId
                WHERE s.projectId = ? AND e.name = 'Stop' AND e.createdAt > ? AND e.createdAt > (
                    SELECT MAX(e2.createdAt) FROM hookEvent e2 JOIN session s2 ON s2.id = e2.sessionId
                    WHERE s2.projectId = ? AND e2.name = 'UserPromptExpansion' AND e2.summary LIKE ?)
                ORDER BY e.createdAt LIMIT 1
                """, arguments: [projectId, date ?? .distantPast, projectId, "/\(ship)%"])
        }
    }

    // MARK: Tasks, morning and evening (SPEC module 7)

    private(set) var tasks: [TaskItem] = []

    func reloadTasks() {
        tasks = (try? db.read { try TaskItem.order(Column("isDone"), Column("createdAt")).fetchAll($0) }) ?? []
    }

    @discardableResult
    func addTask(_ text: String, projectId: Int64?) -> TaskItem? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var task = TaskItem(projectId: projectId, text: text)
        try? db.write { try task.insert($0) }
        reloadTasks()
        return task
    }

    func updateTask(_ task: TaskItem) {
        var task = task
        task.doneAt = task.isDone ? (task.doneAt ?? .now) : nil
        try? db.write { try task.update($0) }
        reloadTasks()
    }

    func deleteTask(_ id: Int64) {
        let owned = tasks.first { $0.id == id }?.attachments.filter { $0.hasPrefix(TaskItem.attachmentsDir.path + "/") } ?? []
        for file in owned { try? FileManager.default.removeItem(atPath: file) }
        _ = try? db.write { try TaskItem.deleteOne($0, id: id) }
        reloadTasks()
    }

    /// Project whose name or repo name the text mentions as a word; nil when none or ambiguous.
    func guessProject(for text: String) -> Int64? {
        let words = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" }.map(String.init))
        let hits = projects.filter { project in
            var names = [project.name.lowercased()]
            if let repo = project.remote?.split(separator: "/").last { names.append(repo.lowercased().replacingOccurrences(of: ".git", with: "")) }
            return names.contains { words.contains($0) }
        }
        return hits.count == 1 ? hits[0].id : nil
    }

    /// Pasted list → one task per line, bullets and numbering stripped.
    static func taskLines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.replacingOccurrences(of: #"^\s*(?:(?:[-*•]|\[.?\]|\d+[.)])\s*)+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Morning: one session per task, the task as its first prompt. A project's second and later
    /// sessions get their own worktree so parallel tasks don't edit the same files (module 5).
    func launchMorning(_ taskIds: [Int64]) throws {
        var busy = Set(sessions.map(\.projectId))
        var worktreeNames = Set(sessions.compactMap(\.worktreeName))
        for id in taskIds {
            guard var task = tasks.first(where: { $0.id == id }), let projectId = task.projectId else { continue }
            var worktree: String?
            if busy.contains(projectId) {
                let base = ClaudeLauncher.worktreeSlug(task.text.split(separator: " ").prefix(4).joined(separator: " "))
                var name = base.isEmpty ? "task" : base
                var n = 2
                while worktreeNames.contains(name) { name = "\(base)-\(n)"; n += 1 }
                worktreeNames.insert(name)
                worktree = name
            }
            try createSession(projectId: projectId, model: nil, prompt: task.prompt, worktree: worktree)
            busy.insert(projectId)
            task.sessionId = selectedSessionId
            try db.write { try task.update($0) }
        }
        reloadTasks()
    }

    struct ProjectDay {
        var project: Project
        var commits: [String]
        var stages: [String]
        var tokens: Int
        var todos: [AgentTodo]
        var nextSteps: String?
        var doneTasks: [String]
        var openTasks: [String]
    }

    /// Evening summary per project with any activity today.
    func daySummary(now: Date = .now) -> [ProjectDay] {
        let start = Calendar.current.startOfDay(for: now)
        let tokens = Dictionary(usageStats(since: start).byProject.map { ($0.name, $0.totals.total) }, uniquingKeysWith: +)
        let syncCommand = stages.first { $0.name == "sync" }?.command ?? "sync"
        return projects.compactMap { project in
            guard let projectId = project.id else { return nil }
            let sessionIds = sessions.filter { $0.projectId == projectId }.compactMap(\.id)
            let marks = sessionIds.map { _ in "?" }.joined(separator: ",")
            let (stages, nextSteps, todos) = (try? db.read { db -> ([String], String?, [AgentTodo]) in
                let todos = try AgentTodo.filter(Column("projectId") == projectId && Column("createdAt") >= start)
                    .order(Column("createdAt")).fetchAll(db)
                guard !sessionIds.isEmpty else { return ([], nil, todos) }
                var args = StatementArguments(sessionIds)
                args += [start]
                let commands = try String.fetchAll(db, sql: """
                    SELECT summary FROM hookEvent WHERE sessionId IN (\(marks)) AND name = 'UserPromptExpansion' AND createdAt >= ?
                    ORDER BY createdAt
                    """, arguments: args)
                // The reply to the day's last sync-stage command (whatever it is called here) or /retro holds the next steps.
                let wrapUp = try Row.fetchOne(db, sql: """
                    SELECT sessionId, createdAt FROM hookEvent WHERE sessionId IN (\(marks)) AND name = 'UserPromptExpansion'
                    AND createdAt >= ? AND (summary LIKE ? OR summary LIKE '/retro%') ORDER BY createdAt DESC LIMIT 1
                    """, arguments: args + ["/\(syncCommand)%"])
                let reply = try wrapUp.flatMap { row in
                    try String.fetchOne(db, sql: """
                        SELECT summary FROM hookEvent WHERE sessionId = ? AND name = 'Stop' AND createdAt >= ? ORDER BY createdAt LIMIT 1
                        """, arguments: [row["sessionId"] as Int64, row["createdAt"] as Date])
                }
                let names = commands.compactMap { $0.split(separator: " ").first.map { String($0.dropFirst()) } }
                return (names.reduce(into: []) { if $0.last != $1 { $0.append($1) } }, reply, todos)
            }) ?? ([], nil, [])
            let projectTasks = tasks.filter { $0.projectId == projectId }
            let day = ProjectDay(
                project: project,
                commits: GitService.commits(since: start, in: project.path),
                stages: stages,
                tokens: tokens[project.name] ?? 0,
                todos: todos,
                nextSteps: nextSteps,
                doneTasks: projectTasks.filter { $0.isDone && ($0.doneAt ?? .distantPast) >= start }.map(\.text),
                openTasks: projectTasks.filter { !$0.isDone }.map(\.text)
            )
            let active = !day.commits.isEmpty || !day.stages.isEmpty || day.tokens > 0 || !day.todos.isEmpty || !day.doneTasks.isEmpty
            return active ? day : nil
        }
    }

    /// Plain text for copying or sharing.
    static func dayText(_ days: [ProjectDay], date: Date = .now) -> String {
        var lines = ["meepo — \(date.formatted(date: .abbreviated, time: .omitted))"]
        for day in days {
            lines.append("")
            lines.append("■ \(day.project.name) — \(TokenFormat.short(day.tokens)) tokens")
            if !day.stages.isEmpty { lines.append("Stages: " + day.stages.joined(separator: " → ")) }
            if !day.doneTasks.isEmpty { lines.append("Done:"); lines += day.doneTasks.map { "  ✓ \($0)" } }
            if !day.commits.isEmpty { lines.append("Commits:"); lines += day.commits.map { "  \($0)" } }
            if !day.todos.isEmpty { lines.append("TODOs left by the agent:"); lines += day.todos.map { "  \(URL(filePath: $0.file).lastPathComponent): \($0.line)" } }
            if let next = day.nextSteps { lines.append("Next steps:"); lines.append(next) }
            if !day.openTasks.isEmpty { lines.append("Open tasks → tomorrow:"); lines += day.openTasks.map { "  ☐ \($0)" } }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Worktrees and ports (SPEC module 5)

    private(set) var mergedWorktreeSessionIds: Set<Int64> = []

    private func nextPortBase() -> Int {
        Ports.nextBase(taken: Set(sessions.compactMap(\.portBase)),
                       listening: Set(Ports.listening().map(\.port)))
    }

    private func assignPortBase(_ sessionId: Int64) {
        guard var session = sessions.first(where: { $0.id == sessionId }) else { return }
        session.portBase = nextPortBase()
        _ = try? db.write { try session.update($0) }
        reload()
    }

    /// Folder a session works in: its worktree, or the project itself.
    func workdir(of session: Session) -> String? {
        guard let project = project(for: session) else { return nil }
        return session.worktreeName.map { ClaudeLauncher.worktreePath($0, projectPath: project.path) } ?? project.path
    }

    /// After the feature is merged: remove the worktree and its branch, close the session.
    func removeWorktree(of sessionId: Int64) {
        guard let session = sessions.first(where: { $0.id == sessionId }), let name = session.worktreeName,
              let project = project(for: session) else { return }
        terminals.close(sessionId) // claude keeps the worktree locked while it runs
        if let error = GitService.removeWorktree(at: ClaudeLauncher.worktreePath(name, projectPath: project.path),
                                                 branch: "worktree-\(name)", in: project.path) {
            bridgeError = error
            startTerminalIfNeeded(sessionId)
            return
        }
        closeSession(sessionId)
    }

    /// Commands and uncommitted changes per project; cheap, refreshed with usage.
    func refreshProjects() {
        var merged: Set<Int64> = []
        for session in sessions {
            guard let id = session.id, let name = session.worktreeName, let base = session.worktreeBase,
                  let project = project(for: session) else { continue }
            if GitService.isMerged(branch: "worktree-\(name)", startedAt: base, in: project.path) { merged.insert(id) }
        }
        mergedWorktreeSessionIds = merged
        var commands: [Int64: [SlashCommand]] = [:]
        var dirty: Set<Int64> = []
        for project in projects {
            guard let id = project.id else { continue }
            commands[id] = CommandCatalog.commands(projectPath: project.path)
            if GitService.hasUncommittedChanges(in: project.path) { dirty.insert(id) }
        }
        commandsByProject = commands
        dirtyProjectIds = dirty
    }

    // MARK: Projects

    /// A folder inside a git repository adds the repository; a folder without git is a project too
    /// (sessions, stages, tokens work; git parts stay hidden).
    func addProject(at url: URL) throws {
        let root = (try? GitService.repositoryRoot(of: url.path)) ?? url.standardizedFileURL.path
        let name = URL(filePath: root).lastPathComponent
        var project = Project(name: name, path: root, remote: GitService.remoteURL(in: root), color: nil)
        do {
            try db.write { try project.insert($0) }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw AddProjectError.alreadyAdded(name)
        }
        if isBridgeInstalled { try? bridge.setNotifyGuard(true, projectPaths: [root]) }
        reload()
    }

    func project(for session: Session) -> Project? {
        projects.first { $0.id == session.projectId }
    }

    // MARK: Sessions

    /// Sidebar order: projects by name, then sessions by creation time. Hotkeys walk this list.
    var orderedSessions: [Session] {
        projects.flatMap { project in sessions.filter { $0.projectId == project.id } }
    }

    var selectedSession: Session? {
        sessions.first { $0.id == selectedSessionId }
    }

    func presentNewSession(projectId: Int64? = nil) {
        newSessionProjectId = projectId ?? selectedSession?.projectId ?? projects.first?.id
    }

    /// `worktree`: a feature name — the session runs in its own git worktree (`claude -w`), SPEC module 5.
    /// `resuming`: an existing Claude Code conversation (e.g. imported from an IDE); it opens with `--resume`.
    func createSession(projectId: Int64, model: String?, prompt: String?, effort: String? = nil, stage: String? = nil,
                       worktree: String? = nil, resuming: String? = nil, name: String? = nil, extraDirs: [String] = []) throws {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        let worktreeName = worktree.map(ClaudeLauncher.worktreeSlug).flatMap { $0.isEmpty ? nil : $0 }
        if worktreeName != nil { GitService.ensureWorktreesIgnored(in: project.path, backups: backupsDir) }
        var session = Session(
            projectId: projectId,
            claudeSessionId: resuming ?? UUID().uuidString.lowercased(),
            model: model,
            effort: effort,
            branch: worktreeName.map { "worktree-\($0)" } ?? GitService.currentBranch(in: project.path),
            stage: stage,
            worktreeName: worktreeName,
            worktreeBase: worktreeName.flatMap { _ in GitService.headCommit(in: project.path) },
            portBase: nextPortBase(),
            status: .idle,
            createdAt: .now,
            lastActiveAt: .now,
            name: name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) },
            extraDirs: extraDirs.isEmpty ? nil : extraDirs
        )
        try db.write { try session.insert($0) }
        if let prompt, !prompt.isEmpty { initialPrompts[session.id!] = prompt }
        reload()
        selectedSessionId = session.id
    }

    /// `meepo <folder>` (via meepo://open?path=…): the folder's project — added if new — with a session open in it.
    func openFromCommandLine(_ url: URL) {
        if url.scheme == "meepo", url.host() == "update" {             // `meepo update`, like `claude update`
            Task { await checkForUpdates(userInitiated: true) }
            return
        }
        guard url.scheme == "meepo", url.host() == "open",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value
        else { return }
        let root = (try? GitService.repositoryRoot(of: path)) ?? URL(filePath: path).standardizedFileURL.path
        if !projects.contains(where: { $0.path == root }) {
            do { try addProject(at: URL(filePath: path)) } catch { bridgeError = error.localizedDescription; return }
        }
        guard let project = projects.first(where: { $0.path == root }), let projectId = project.id else { return }
        if let latest = orderedSessions.last(where: { $0.projectId == projectId }) {
            selectedSessionId = latest.id
        } else {
            try? createSession(projectId: projectId, model: nil, prompt: nil)
        }
    }

    /// A fresh claude in the same folder — same worktree, branch and ports — and the old session closed.
    /// The old conversation stays in ~/.claude (claude --resume can still open it).
    func replaceSession(_ id: Int64) throws {
        guard let old = sessions.first(where: { $0.id == id }) else { return }
        let fresh = try successor(of: old, model: old.model, effort: old.effort, stage: nil, prompt: nil, keepsPorts: true)
        closeSession(id)
        selectedSessionId = fresh
    }

    /// A new session that carries on where `old` works: the same worktree (or project folder) and branch,
    /// never the main folder by accident. `keepsPorts` when the old one closes; otherwise both run at once
    /// and the new one gets its own port range.
    @discardableResult
    func successor(of old: Session, model: String?, effort: String?, stage: String?, prompt: String?,
                   keepsPorts: Bool) throws -> Int64? {
        var fresh = Session(
            projectId: old.projectId,
            claudeSessionId: UUID().uuidString.lowercased(),
            model: model,
            effort: effort,
            branch: old.branch,
            stage: stage,
            worktreeName: old.worktreeName,
            worktreeBase: old.worktreeBase,
            portBase: keepsPorts ? old.portBase : nextPortBase(),
            status: .idle,
            createdAt: .now,
            lastActiveAt: .now,
            name: old.name,
            extraDirs: old.extraDirs
        )
        try db.write { try fresh.insert($0) }
        if let prompt, !prompt.isEmpty { initialPrompts[fresh.id!] = prompt }
        reload()
        selectedSessionId = fresh.id
        return fresh.id
    }

    /// Takes a project out of Meepo: its sessions close; the folder, git and Claude's conversations stay,
    /// and the user's own Notification hooks there get their original form back.
    func removeProject(_ id: Int64) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        for session in sessions where session.projectId == id { if let sid = session.id { closeSession(sid) } }
        if isBridgeInstalled { try? bridge.setNotifyGuard(false, projectPaths: [project.path]) }
        _ = try? db.write { try Project.deleteOne($0, id: id) }
        ciRuns[id] = nil
        pipelines[id] = nil
        reload()
    }

    func closeSession(_ id: Int64) {
        let ordered = orderedSessions
        terminals.close(id)
        runningSessionIds.remove(id)
        exitedSessionIds.remove(id)
        initialPrompts[id] = nil
        _ = try? db.write { try Session.deleteOne($0, id: id) }
        if selectedSessionId == id, let index = ordered.firstIndex(where: { $0.id == id }) {
            let rest = ordered.filter { $0.id != id }
            selectedSessionId = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
        }
        reload()
    }

    // MARK: Terminals

    func terminalView(for sessionId: Int64) -> LocalProcessTerminalView? {
        terminals.view(for: sessionId)
    }

    /// Starts `claude` for the session: `--resume` if Claude Code already has its transcript
    /// (e.g. after Meepo restarted), otherwise a fresh start with the same session id.
    /// Waits for `restoreSessions` to resolve the login environment (it then starts every session);
    /// only if that resolution failed does claude go through the shell fallback.
    func startTerminalIfNeeded(_ sessionId: Int64) {
        guard isLoginResolved, let login = loginEnvironment, terminals.view(for: sessionId) == nil,
              let existing = sessions.first(where: { $0.id == sessionId }),
              let project = project(for: existing) else { return }
        if existing.portBase == nil { assignPortBase(sessionId) } // sessions from before module 5
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        terminals.start(session, projectPath: project.path, initialPrompt: initialPrompts.removeValue(forKey: sessionId),
                        login: login,
                        remoteControlName: remoteControlForNewSessions ? [project.name, session.branch].compactMap { $0 }.joined(separator: " · ") : nil,
                        guided: guidedMode)
        runningSessionIds.insert(sessionId)
    }

    func restartSession(_ id: Int64) {
        terminals.close(id)
        exitedSessionIds.remove(id)
        startTerminalIfNeeded(id)
    }

    // MARK: Navigation

    func selectSession(offset: Int) {
        let ordered = orderedSessions
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == selectedSessionId } ?? (offset > 0 ? -1 : 0)
        let next = ((current + offset) % ordered.count + ordered.count) % ordered.count
        selectedSessionId = ordered[next].id
    }

    /// 1-based, matching Cmd+1..9.
    func selectSession(number: Int) {
        let ordered = orderedSessions
        guard ordered.indices.contains(number - 1) else { return }
        selectedSessionId = ordered[number - 1].id
    }

    /// Next session (after the current one, wrapping) that waits for the user.
    func selectNextWaiting() {
        let ordered = orderedSessions
        let start = (ordered.firstIndex { $0.id == selectedSessionId } ?? -1) + 1
        let rotated = ordered[min(start, ordered.count)...] + ordered[..<min(start, ordered.count)]
        if let waiting = rotated.first(where: { $0.status == .waitingInput || $0.status == .waitingPermission }) {
            selectedSessionId = waiting.id
        }
    }
}

// MARK: Demo mode

extension AppStore {
    /// Fills an empty store with Demo's made-up projects: real git folders in a temp directory (so Source
    /// Control and Explorer work), sessions in every state, an hour of events, live numbers, a summary and
    /// suggestions. Nothing of the user's is read or written.
    func loadDemo() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "Meepo Demo")
        try? FileManager.default.removeItem(at: root)
        let identity = ["-c", "user.name=Meepo", "-c", "user.email=demo@meepo.app"]
        for project in Demo.projects {
            let folder = root.appending(path: project.name)
            for (file, text) in project.files {
                let url = folder.appending(path: file)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            _ = GitService.runReportingError(["init", "-q", "-b", "main"], in: folder.path)
            _ = GitService.runReportingError(["add", "."], in: folder.path)
            _ = GitService.runReportingError(identity + ["commit", "-q", "-m", "Start"], in: folder.path)
            _ = GitService.runReportingError(["remote", "add", "origin", "git@github.com:acme/\(project.name).git"], in: folder.path)
            let changed = folder.appending(path: project.change.file)
            try? FileManager.default.createDirectory(at: changed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? project.change.text.write(to: changed, atomically: true, encoding: .utf8)
            try? addProject(at: folder)
        }
        isBridgeInstalled = true
        isLoginResolved = true
        for spec in Demo.sessions {
            guard let project = projects.first(where: { $0.name == spec.project }), let projectId = project.id else { continue }
            try? createSession(projectId: projectId, model: nil, prompt: nil, name: spec.name)
            guard let session = sessions.last, let id = session.id else { continue }
            // An hour of activity for the Timeline, then the event that sets today's state.
            let start = Date.now.addingTimeInterval(-Double.random(in: 1200...3000))
            _ = try? await db.write { db in
                var events = [HookEvent(sessionId: id, name: "UserPromptSubmit", summary: spec.request, isFailure: false, createdAt: start)]
                for (i, file) in spec.files.enumerated() {
                    events.append(HookEvent(sessionId: id, name: "PostToolUse", summary: "Write: \(project.path)/\(file)",
                                            isFailure: false, createdAt: start.addingTimeInterval(Double(i + 1) * 240)))
                }
                for minute in stride(from: 3, to: 20, by: 4) {
                    events.append(HookEvent(sessionId: id, name: "PreToolUse", summary: "Bash: npm test", isFailure: false,
                                            createdAt: start.addingTimeInterval(Double(minute) * 60)))
                }
                for var event in events { try event.insert(db) }
            }
            let event: HookPayload = switch spec.state {
            case "permission": HookPayload(event: "PermissionRequest", claudeSessionId: session.claudeSessionId, toolName: "Bash",
                                           toolTarget: "pytest tests/monitoring -q")
            case "question": HookPayload(event: "Stop", claudeSessionId: session.claudeSessionId,
                                         lastAssistantMessage: "Should sessions last 30 days, or 24 hours?")
            case "ready": HookPayload(event: "Stop", claudeSessionId: session.claudeSessionId,
                                      lastAssistantMessage: "Done. The welcome screen now says “Your rides, one tap away”.")
            default: HookPayload(event: "PreToolUse", claudeSessionId: session.claudeSessionId, toolName: "Edit",
                                 toolTarget: "src/admin/report.ts")
            }
            handleHookEvent(event, sessionId: id)
            if spec.state == "ready" { // finished earlier: ready for the next task, not waiting on an answer
                handleHookEvent(HookPayload(event: "SessionStart", claudeSessionId: session.claudeSessionId), sessionId: id)
            }
            terminals.showText(spec.terminal, for: id)
            runningSessionIds.insert(id)
            sessionUsage[id] = SessionUsage(tokensToday: spec.tokens, contextTokens: Int(spec.context * 10_000), model: spec.model)
            if let status = StatusLine(json: Demo.statusLine(for: spec)) { applyStatusLine(status, sessionId: id) }
        }
        // A finished run with its summary, for What changed.
        if let first = sessions.first, let id = first.id {
            let started = Date.now.addingTimeInterval(-5400)
            _ = try? await db.write { db in
                var submit = HookEvent(sessionId: id, name: "UserPromptSubmit", summary: "add refunds for Kaspi payments to the checkout",
                                       isFailure: false, createdAt: started)
                try submit.insert(db)
                var edit = HookEvent(sessionId: id, name: "PostToolUse", summary: "Write: src/payments/refund.ts", isFailure: false,
                                     createdAt: started.addingTimeInterval(300))
                try edit.insert(db)
                var stop = HookEvent(sessionId: id, name: "Stop", summary: "Refunds work end to end.", isFailure: false,
                                     createdAt: started.addingTimeInterval(900))
                try stop.insert(db)
                try db.execute(sql: "INSERT INTO runSummary (sessionId, startedAt, json, createdAt) VALUES (?, ?, ?, ?)",
                               arguments: [id, started, Demo.summary, Date.now])
            }
        }
        suggestions = [Noticing.Suggestion(kind: .chain(["simplify", "ship", "sync"]), count: 25),
                       Noticing.Suggestion(kind: .skill(phrase: "check the staging deploy and tell me what broke"), count: 7)]
        defaults.set("2.1.281", forKey: "claudeCodeVersionSeen")
        let changelog = (try? String(contentsOf: ClaudeChangelog.cacheFile, encoding: .utf8)) ?? ""
        noteClaudeVersion("2.1.282", changelog: changelog)
        selectedSessionId = sessions.first?.id
    }
}
