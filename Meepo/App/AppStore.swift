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
    private var isLoginResolved = false

    private(set) var projects: [Project] = []
    private(set) var sessions: [Session] = []
    private(set) var runningSessionIds: Set<Int64> = []
    private(set) var exitedSessionIds: Set<Int64> = []
    var selectedSessionId: Int64? {
        didSet { reloadEvents() }
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
        relayThreshold = defaults.object(forKey: Self.relayThresholdKey) as? Double ?? 0.7
        remoteControlForNewSessions = defaults.bool(forKey: Self.remoteControlKey)
        autofixProjectIds = Set((defaults.array(forKey: Self.autofixKey) as? [Int64]) ?? [])
        fixAttempts = (defaults.dictionary(forKey: Self.fixAttemptsKey) as? [String: Int]) ?? [:]
        screenshotHotKey = defaults.string(forKey: Self.shotHotKeyKey) ?? "⌘⇧6"
        libraryFolder = defaults.string(forKey: Self.libraryKey)
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude").path
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
        loginEnvironment = await Task.detached { ClaudeLauncher.resolveLoginEnvironment() }.value
        isLoginResolved = true
        for session in orderedSessions {
            if let id = session.id { startTerminalIfNeeded(id) }
        }
    }

    func reload() {
        projects = (try? db.read { try Project.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll($0) }) ?? []
        sessions = (try? db.read { try Session.order(Column("createdAt")).fetchAll($0) }) ?? []
    }

    // MARK: Hook events

    var waitingCount: Int {
        sessions.filter { $0.status == .waitingInput || $0.status == .waitingPermission }.count
    }

    /// Applies a hook event to its session; returns what (if anything) the user should be told.
    @discardableResult
    func handleHookEvent(_ payload: HookPayload, sessionId: Int64) -> Attention? {
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
        if payload.event == "Stop", relayingSessionIds.contains(sessionId) {
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

    /// Context window per model (design: "sizes in settings"); unknown models get 200K.
    var contextWindows: [String: Int] {
        didSet { defaults.set(try? JSONEncoder().encode(contextWindows), forKey: Self.contextWindowsKey) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    func contextWindow(for model: String?) -> Int {
        model.flatMap { contextWindows[$0] } ?? Self.defaultContextWindow
    }

    /// 0…1 (can exceed 1 if the window setting is too small); nil before the first response.
    func contextFraction(for sessionId: Int64) -> Double? {
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
        refreshProjects()
    }

    /// A newer Meepo on GitHub Releases, checked daily.
    var availableUpdate: UpdateCheck.Release?

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
        let names = Set((commandsByProject[projectId] ?? []).map(\.name))
        return stages.filter { $0.command == nil || names.contains($0.command!) }
    }

    /// A slash command enters its stage; a plain prompt right after a stage moves on to a following
    /// command-less stage (plan → code).
    func nextStage(after current: String?, for payload: HookPayload) -> String? {
        if payload.event == "UserPromptExpansion", let command = payload.commandName {
            return stages.first { $0.command == command }?.name
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
        let qa = stages.first { $0.name == "qa" }?.command ?? "qa"
        return (try? db.read { db in
            let lastEdit = try Date.fetchOne(db, sql: """
                SELECT MAX(createdAt) FROM hookEvent WHERE sessionId = ? AND name = 'PostToolUse'
                AND (summary LIKE 'Edit:%' OR summary LIKE 'Write:%' OR summary LIKE 'MultiEdit:%' OR summary LIKE 'NotebookEdit:%')
                """, arguments: [sessionId])
            let lastQA = try Date.fetchOne(db, sql: """
                SELECT MAX(createdAt) FROM hookEvent WHERE sessionId = ? AND name = 'UserPromptExpansion' AND summary LIKE ?
                """, arguments: [sessionId, "/\(qa)%"])
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
        try createSession(projectId: session.projectId, model: code?.model ?? session.model,
                          prompt: "Implement the plan below, prepared in a previous session.\n\n\(plan)\(decisions)",
                          effort: code?.effort, stage: code?.name)
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
            try createSession(projectId: old.projectId, model: old.model,
                              prompt: "Continue the task of the previous session (its context was full).\(handoff)",
                              effort: old.effort, stage: old.stage)
            closeSession(sessionId)
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
        } catch {
            bridgeError = error.localizedDescription
        }
        refreshProjects()
    }

    // MARK: CI guard (SPEC module 9)

    private static let autofixKey = "ciAutofixProjects"
    private static let fixAttemptsKey = "ciFixAttempts"

    /// Right panel tab; the card's CI badge switches it to CI.
    var feedTab = EventFeedView.Tab.events
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
        isCIPrimed = true
    }

    /// Fix session in its own worktree with the failed step's log and guardrails in its first prompt.
    func startCIFix(_ run: CIRun, in project: Project, provider: (any CIProvider)? = nil) async {
        guard let provider = provider ?? ciProvider(for: project), let projectId = project.id else { return }
        let log = await provider.failedLog(run, in: project.path)
        fixAttempts["\(projectId)|\(run.key)", default: 0] += 1
        let name = "ci-fix-\(ClaudeLauncher.worktreeSlug(run.headBranch))-\(run.databaseId % 100_000)"
        do {
            try createSession(projectId: projectId, model: nil, prompt: CIGuard.fixPrompt(run, log: log), worktree: name)
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
            let text = try await ReleaseNotes.generate(prompt, claude: login.claudePath, environment: login.environment)
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
                // The reply to the day's last /sync or /retro holds the next steps.
                let wrapUp = try Row.fetchOne(db, sql: """
                    SELECT sessionId, createdAt FROM hookEvent WHERE sessionId IN (\(marks)) AND name = 'UserPromptExpansion'
                    AND createdAt >= ? AND (summary LIKE '/sync%' OR summary LIKE '/retro%') ORDER BY createdAt DESC LIMIT 1
                    """, arguments: args)
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
        var lines = ["Meepo — \(date.formatted(date: .abbreviated, time: .omitted))"]
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

    func addProject(at url: URL) throws {
        let root = try GitService.repositoryRoot(of: url.path)
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
                       worktree: String? = nil, resuming: String? = nil) throws {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        let worktreeName = worktree.map(ClaudeLauncher.worktreeSlug).flatMap { $0.isEmpty ? nil : $0 }
        if worktreeName != nil { GitService.ensureWorktreesIgnored(in: project.path) }
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
            lastActiveAt: .now
        )
        try db.write { try session.insert($0) }
        if let prompt, !prompt.isEmpty { initialPrompts[session.id!] = prompt }
        reload()
        selectedSessionId = session.id
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
        guard isLoginResolved, terminals.view(for: sessionId) == nil,
              let existing = sessions.first(where: { $0.id == sessionId }),
              let project = project(for: existing) else { return }
        if existing.portBase == nil { assignPortBase(sessionId) } // sessions from before module 5
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        terminals.start(session, projectPath: project.path, initialPrompt: initialPrompts.removeValue(forKey: sessionId),
                        login: loginEnvironment,
                        remoteControlName: remoteControlForNewSessions ? [project.name, session.branch].compactMap { $0 }.joined(separator: " · ") : nil)
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
