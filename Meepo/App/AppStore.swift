import Foundation
import GRDB
import Observation
import SwiftTerm

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
    private var loginEnvironment: ClaudeLauncher.LoginEnvironment?
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
        // Processes restart with Meepo, so statuses from the previous run are stale.
        _ = try? db.write { db in
            try db.execute(sql: "UPDATE session SET status = ?", arguments: [SessionStatus.idle])
            try db.execute(sql: "DELETE FROM hookEvent WHERE createdAt < ?",
                           arguments: [Date.now.addingTimeInterval(-Self.eventRetention)])
        }
        reload()
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
    func recentModels() -> [String] {
        (try? db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT model FROM usageRecord WHERE createdAt >= ? ORDER BY model",
                                arguments: [Date.now.addingTimeInterval(-30 * 24 * 3600)])
        }) ?? []
    }

    // MARK: Stages and relay (SPEC module 4)

    private static let stagesKey = "stages"
    private static let relayThresholdKey = "relayThreshold"

    /// The user's workflow, set once for all projects.
    var stages: [Stage] {
        didSet { defaults.set(try? JSONEncoder().encode(stages), forKey: Self.stagesKey) }
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
    func createSession(projectId: Int64, model: String?, prompt: String?, effort: String? = nil, stage: String? = nil,
                       worktree: String? = nil) throws {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        let worktreeName = worktree.map(ClaudeLauncher.worktreeSlug).flatMap { $0.isEmpty ? nil : $0 }
        if worktreeName != nil { GitService.ensureWorktreesIgnored(in: project.path) }
        var session = Session(
            projectId: projectId,
            claudeSessionId: UUID().uuidString.lowercased(),
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
                        login: loginEnvironment)
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
