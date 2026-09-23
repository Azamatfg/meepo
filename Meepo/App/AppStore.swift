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
    /// First prompt of a freshly created session; used once, never stored.
    private var initialPrompts: [Int64: String] = [:]
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

    init(db: DatabaseQueue, bridge: BridgeInstaller = BridgeInstaller(), usageRoot: URL = UsageScanner.defaultRoot) {
        self.db = db
        self.bridge = bridge
        self.usageRoot = usageRoot
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
    var contextWindows: [String: Int] = (UserDefaults.standard.data(forKey: contextWindowsKey))
        .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(contextWindows), forKey: Self.contextWindowsKey) }
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

    func createSession(projectId: Int64, model: String?, prompt: String?) throws {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        var session = Session(
            projectId: projectId,
            claudeSessionId: UUID().uuidString.lowercased(),
            model: model,
            branch: GitService.currentBranch(in: project.path),
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
              let session = sessions.first(where: { $0.id == sessionId }),
              let project = project(for: session) else { return }
        terminals.start(session, in: project.path, initialPrompt: initialPrompts.removeValue(forKey: sessionId),
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
