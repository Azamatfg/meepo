import AppKit
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
            focusedUnit = nil
            if let id = selectedSessionId, paneAnchor.map({ paneWindow(from: $0, count: shell.split).contains(id) }) != true {
                paneAnchor = id
            }
        }
    }
    /// Non-nil while the "new session" sheet is shown; the project preselected in it.
    var newSessionProjectId: Int64?
    /// The Settings sheet: ⌘, the ≡ menu and the rail's gear open it.
    var isSettingsShown = false
    /// The Tools sheet, open on this tab; nil = closed. Menus anywhere can open it on Servers.
    var toolsTab: ToolsView.Tab?
    /// Servers opens with this project's Add server form, and the new server's shell opens once it's added.
    var addServerProjectId: Int64?

    /// What Tools → DATABASES opens with, from a session's menu: the wizard for a project, or a database's schema.
    enum DatabaseRequest: Equatable {
        case add(projectId: Int64)
        case schema(databaseId: Int64)
    }

    var databaseRequest: DatabaseRequest?

    func presentDatabases(_ request: DatabaseRequest) {
        databaseRequest = request
        toolsTab = .databases
    }

    /// "Add a server…" in a menu: straight to the form for the project being worked on.
    func presentAddServer(projectId: Int64?) {
        addServerProjectId = projectId ?? selectedSession?.projectId ?? projects.first?.id
        toolsTab = .servers
    }
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
        defaults.removeObject(forKey: "contextWindows") // sizes once set by hand; Claude Code reports the window now
        stages = Self.load([Stage].self, Self.stagesKey, from: defaults) ?? Stage.defaults
        guidedMode = defaults.bool(forKey: Self.guidedKey)
        Self.retireChains(from: defaults)
        suggestionStates = Self.load([String: SuggestionState].self, Self.suggestionsKey, from: defaults) ?? [:]
        skillButtons = defaults.stringArray(forKey: Self.skillButtonsKey) ?? []
        Self.retireCustomLayout(from: defaults)
        let preset = defaults.string(forKey: Self.shellPresetKey).flatMap(ShellLayout.Preset.init(rawValue:)) ?? .focus
        shellPreset = preset
        editedLayouts = Dictionary(uniqueKeysWithValues: (Self.load([String: ShellLayout].self, Self.editedLayoutsKey, from: defaults) ?? [:])
            .compactMap { key, layout in ShellLayout.Preset(rawValue: key).map { ($0, layout) } })
        shell = Self.load(ShellLayout.self, Self.shellKey, from: defaults) ?? ShellLayout.preset(preset)
        relayThreshold = defaults.object(forKey: Self.relayThresholdKey) as? Double ?? 0.7
        remoteControlForNewSessions = defaults.bool(forKey: Self.remoteControlKey)
        shellsBeside = defaults.object(forKey: Self.shellsBesideKey) as? Bool ?? true
        learnsUsage = defaults.object(forKey: Self.learnsUsageKey) as? Bool ?? true
        tabOrder = (defaults.array(forKey: Self.tabOrderKey) as? [Int64]) ?? []
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(Appearance.init) ?? .system
        autofixProjectIds = Set((defaults.array(forKey: Self.autofixKey) as? [Int64]) ?? [])
        fixAttempts = (defaults.dictionary(forKey: Self.fixAttemptsKey) as? [String: Int]) ?? [:]
        screenshotHotKey = defaults.string(forKey: Self.shotHotKeyKey) ?? "⌘⇧6"
        autoUpdate = defaults.object(forKey: Self.autoUpdateKey) as? Bool ?? true
        updateChannel = defaults.string(forKey: Self.channelKey).flatMap(Updater.Channel.init(rawValue:))
            ?? (Updater.currentVersion?.isPrerelease ?? true ? .beta : .stable)
        defaults.removeObject(forKey: "libraryFolder") // Tools → Practices is gone: ~/.claude already serves every project
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
        reloadTitles()
        reloadLastLines()
        for folder in workFolders { reloadRuns(folder) }
        selectedSessionId = orderedSessions.first?.id
        isBridgeInstalled = bridge.isInstalled()
        refreshVoice()
        terminals.onExit = { [weak self] id in self?.sessionExited(id) }
        terminals.onAppearanceChange = { [weak self] dark in self?.appearanceChanged(dark: dark) }
    }

    func sessionExited(_ id: Int64) {
        runningSessionIds.remove(id)
        exitedSessionIds.insert(id)
        holds[id] = nil
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
        for session in orderedSessions where session.agentId == nil {
            if let id = session.id { startTerminalIfNeeded(id) }
        }
        // An agent opened here re-attaches if it still runs, else its conversation resumes: the list decides
        // (at most `claude agents`' timeout; without it they attach, see attachId).
        if sessions.contains(where: { $0.agentId != nil }) { await refreshElsewhere() }
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

    /// What to call a session: the user's name for it, else Claude Code's title for the conversation (its
    /// statusline's session_name: /rename, else the title Claude Code writes itself), else the title in its
    /// transcript, else its first typed request — so two sessions of one project read differently everywhere.
    func displayName(of session: Session) -> String {
        if let name = session.name { return name }
        if session.isLocalTerminal { return "terminal" }
        if let host = session.sshHost { return host }
        if let id = session.id, let named = liveStatus[id]?.sessionName, !named.isEmpty { return named }
        if let id = session.id, let title = titles[id] { return Notifier.plainText(title, limit: 40) }
        return session.worktreeName.map { "worktree \($0)" } ?? session.branch ?? "session"
    }

    /// Per session: Claude Code's title from its transcript, else the first request the user typed (Claude
    /// Code's own turns — a helper's report — don't count). Kept here so no view reads the database.
    private(set) var titles: [Int64: String] = [:]

    private func reloadTitles() {
        var result: [Int64: String] = [:]
        try? db.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT sessionId, summary FROM hookEvent WHERE name = 'UserPromptSubmit' AND summary <> '' ORDER BY createdAt, id
                """)
            while let row = try rows.next() {
                let id: Int64 = row["sessionId"]
                guard result[id] == nil, let typed = Runs.typed(row["summary"]), !typed.isEmpty else { continue }
                result[id] = typed
            }
        }
        titles = result
    }

    /// Claude Code's own titles, from the end of each session's transcript (off the main thread): until a
    /// session's first statusline, that's the name it has in Claude Code.
    func refreshTitles() async {
        let files = sessions.compactMap { session -> (Int64, URL)? in
            guard let id = session.id, session.sshHost == nil, let folder = workdir(of: session) else { return nil }
            return (id, claudeHome.appending(path: "projects/\(ClaudeImport.claudeFolderName(for: folder))/\(session.claudeSessionId).jsonl"))
        }
        let found = await Task.detached {
            files.compactMap { id, file in ClaudeImport.title(of: file, orLastPrompt: false).map { (id, $0) } }
        }.value
        for (id, title) in found where titles[id] != title { titles[id] = title }
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
        if !clean.isEmpty, session.sshHost == nil, runningSessionIds.contains(sessionId) { type("/rename \(clean)\r", into: sessionId) }
    }

    // MARK: Onboarding — the two ways in

    private static let guidedKey = "guidedMode"

    /// For people new to Claude Code: Meepo's sessions explain as they go and ask before risky commands.
    /// Takes effect for sessions started (or restarted) after the change.
    var guidedMode: Bool {
        didSet { defaults.set(guidedMode, forKey: Self.guidedKey) }
    }

    /// Sessions whose claude started in Guided mode: claude reads the mode once, when it starts.
    private(set) var guidedSessionIds: Set<Int64> = []
    /// Per session, the last hook event that moved its turn (a Notification only repeats one), for `guidedRestart`.
    private(set) var lastTurnEvents: [Int64: String] = [:]

    struct TurnState {
        let id: Int64
        let status: SessionStatus
        /// "Stop", "PermissionRequest", "PreToolUse"…; nil = nothing since claude started.
        let lastEvent: String?
        let runsGuided: Bool
    }

    /// The running sessions still in the other mode. `now`: between turns — ready, Claude's answer was the last
    /// word (Stop, or StopFailure: an API error ended the turn), or claude only just (re)started and has sat
    /// waiting since (SessionStart, then an idle-prompt Notification) — so a restart continues the same conversation
    /// and cuts nothing off. `later`: mid-turn, or waiting on a permission or on a question Claude asked
    /// (AskUserQuestion, which also reads "waiting for you"). Idle counts only when hooks told us so (`hooks`: the
    /// bridge is installed): without them every session stays idle, even mid-turn.
    static func guidedRestart(_ sessions: [TurnState], guided: Bool, hooks: Bool) -> (now: [Int64], later: [Int64]) {
        let other = sessions.filter { $0.runsGuided != guided }
        let isFree = { (s: TurnState) in
            switch s.status {
            case .idle: hooks && ["SessionStart", "SessionEnd", "Stop", "StopFailure"].contains(s.lastEvent ?? "")
            case .waitingInput: s.lastEvent == "Stop" || s.lastEvent == "SessionStart"
            case .error: s.lastEvent == "StopFailure"
            default: false
            }
        }
        return (other.filter(isFree).map(\.id), other.filter { !isFree($0) }.map(\.id))
    }

    private var turnStates: [TurnState] {
        sessions.compactMap { session in
            guard let id = session.id, session.sshHost == nil, runningSessionIds.contains(id), !exitedSessionIds.contains(id)
            else { return nil }
            return TurnState(id: id, status: session.status, lastEvent: lastTurnEvents[id], runsGuided: guidedSessionIds.contains(id))
        }
    }

    /// ≡ → Guided mode: switches it and says what that changes. claude reads the mode only when it starts
    /// (`--settings` is pinned then), so sessions between turns are offered a restart; the others keep their mode
    /// until meepo next opens, which restarts every session (claude --resume).
    func setGuidedMode(_ on: Bool) {
        guidedMode = on
        let states = turnStates
        let (now, later) = Self.guidedRestart(states, guided: on, hooks: isBridgeInstalled)
        let explaining = states.filter { state in
            !state.runsGuided && ["Explanatory", "Learning"].contains(liveStatus[state.id]?.outputStyle ?? "")
        }.count
        func sessions(_ count: Int) -> String { count == 1 ? "1 session" : "\(count) sessions" }
        // Which ones, as their tabs read: a bare count leaves the user guessing.
        func names(_ ids: [Int64]) -> String {
            ids.compactMap { id in self.sessions.first { $0.id == id }.map(tabLabel) }.joined(separator: ", ")
        }
        var message = on
            ? "Claude explains what it does and why as it works, and asks you first before it pushes code, deletes a folder, uses sudo, publishes a package or edits .env secrets — even in auto mode. New sessions start guided."
            : "New sessions start without it: no teaching notes, and no extra questions before a push, deleting a folder, sudo, publishing a package or a .env edit. Your own permission rules still apply."
        if on, explaining > 0 {
            message += " In \(explaining == 1 ? "1 running session" : "\(explaining) running sessions") Claude already explains — your own output style; guided adds asking first."
        }
        if !now.isEmpty {
            message += "\n\n\(sessions(now.count)) between turns can switch now (\(names(now))): a restart continues the same conversation, and its next reply reads the conversation again once, so that reply costs more."
        }
        if !later.isEmpty {
            message += "\n\n\(sessions(later.count)) \(later.count == 1 ? "is" : "are") busy — working, or waiting on your answer — and keep\(later.count == 1 ? "s" : "") the old mode for now: \(names(later))."
        }
        if !now.isEmpty || !later.isEmpty {
            message += "\n\nLater: new sessions follow the change right away, running ones the next time meepo opens — it restarts every session then."
        }
        confirmation = PixelConfirmation(
            title: on ? "Guided mode is on" : "Guided mode is off", message: message,
            action: now.isEmpty ? "OK" : "Restart \(sessions(now.count))", cancel: now.isEmpty ? nil : "Later", isDestructive: false
        ) { [weak self] in self?.restartIntoGuidedMode(now) }
    }

    /// Restarts the sessions the notice named, when the user says so — only those still between turns (they may
    /// have moved on since), and never one that became free while it was open: that one wasn't offered.
    private func restartIntoGuidedMode(_ offered: [Int64]) {
        for id in Self.guidedRestart(turnStates, guided: guidedMode, hooks: isBridgeInstalled).now where offered.contains(id) {
            if isDemo { // nothing runs in Demo: only the mode changes
                if guidedMode { guidedSessionIds.insert(id) } else { guidedSessionIds.remove(id) }
            } else {
                restartSession(id)
            }
        }
    }

    /// `claude auth status` after the login shell is known; nil = couldn't tell.
    private(set) var isClaudeLoggedIn: Bool?
    /// How claude is signed in ("claude.ai", "api_key"…); voice needs a Claude.ai sign-in.
    private(set) var claudeAuthMethod: String?

    func checkClaudeLogin() async {
        guard let login = loginEnvironment else { isClaudeLoggedIn = nil; claudeAuthMethod = nil; return }
        let status = await Task.detached { ClaudeLauncher.authStatus(login: login) }.value
        isClaudeLoggedIn = status?.loggedIn
        claudeAuthMethod = status?.method
    }

    /// The end of Welcome. The first time, it sets meepo up for the way in chosen — the layout, and Guided mode;
    /// opened again from ≡ it changes neither (a layout set up once stays). The project picked in it gets a new
    /// session, opened.
    func finishOnboarding(newcomer: Bool, guided: Bool, projectId: Int64?, isFirstRun: Bool) throws {
        if isFirstRun {
            guidedMode = guided
            applyPreset(newcomer ? .focus : .full)
        }
        if let projectId { try createSession(projectId: projectId, model: nil, prompt: nil) }
    }

    /// The project for a folder the user picked: added when it's new, the one already there when not.
    func project(forFolder url: URL) throws -> Project? {
        let root = (try? GitService.repositoryRoot(of: url.path)) ?? url.standardizedFileURL.path
        if !projects.contains(where: { $0.path == root }) { try addProject(at: url) }
        return projects.first { $0.path == root }
    }

    /// A new, empty project: the folder, `git init` (so changes are tracked and can be compared), added to Meepo.
    @discardableResult
    func createProject(named name: String, in parent: URL) throws -> Project? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/") else { throw ClaudeHeadless.Failure(errorDescription: "Give the project a name") }
        let folder = parent.appending(path: clean)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            let shown = folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            throw ClaudeHeadless.Failure(errorDescription: "\(shown) already exists — pick another name, or choose it with “A folder I have…”")
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
                                   commands: SetupCheck.userCommands(claudeHome: claudeHome))
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

    // MARK: What changed — units of work from git, and what they mean for the product's users

    /// Per folder a session works in: pushes, what isn't sent yet, and the requests made there. Views read this
    /// (and `lastLine`, `titles`) — never git or the database.
    private(set) var work: [String: Work.Folder] = [:]
    /// Explanations being written right now, by unit key.
    private(set) var explainingUnits: Set<String> = []

    /// Which unit What changed opens on: Today's click on a push. Picking another session forgets it.
    struct FocusedUnit: Equatable {
        let folder: String
        let unit: String
    }
    var focusedUnit: FocusedUnit?
    /// What changed as a sheet: Today's click when the panel isn't in the layout.
    var isWhatChangedShown = false

    private var workFolders: Set<String> { Set(sessions.compactMap(workdir(of:))) }

    /// Every session's folder: git off the main thread, then the requests. At launch, when meepo comes to the
    /// front, after auto-sync.
    func refreshWork() async {
        for folder in workFolders { await refreshWork(folder) }
    }

    /// Per folder, the latest `refreshWork` started: an older read that finishes later is dropped.
    private var workReads: [String: Int] = [:]

    /// One folder: its repos' pushes and what isn't sent (git, off the main thread), then its requests.
    func refreshWork(_ folder: String) async {
        let since = Date.now.addingTimeInterval(-Self.eventRetention)
        let read = (workReads[folder] ?? 0) + 1
        workReads[folder] = read
        let repos = await Task.detached {
            Work.read(Repos.find(in: folder).map { (name: $0.name, path: $0.path) }, since: since)
        }.value
        guard workReads[folder] == read else { return }
        var folderWork = work[folder] ?? Work.Folder()
        (folderWork.repos, folderWork.isGitRead) = (repos, true)
        if work[folder] != folderWork { work[folder] = folderWork }
        reloadRuns(folder)
    }

    /// After Push or Pull in meepo: the folders that repo belongs to.
    func refreshWork(containing repoPath: String) async {
        for folder in work.keys where folder == repoPath || repoPath.hasPrefix(folder + "/")
            || work[folder]?.repos.contains(where: { $0.path == repoPath }) == true {
            await refreshWork(folder)
        }
    }

    /// The folder's requests (every session working there) and their explanations, from the database.
    func reloadRuns(_ folder: String) {
        let ids = sessions.filter { workdir(of: $0) == folder }.compactMap(\.id)
        guard !ids.isEmpty else { return }
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        let (events, summaries) = (try? db.read { db -> ([HookEvent], [String: ProductSummary]) in
            // Only what a run is made of: requests, answers, its end, and file edits (not every read and command).
            let events = try HookEvent.fetchAll(db, sql: """
                SELECT * FROM hookEvent WHERE sessionId IN (\(marks))
                AND (name IN ('UserPromptSubmit', 'UserPromptExpansion', 'Stop', 'StopFailure', 'SessionEnd')
                OR (name = 'PostToolUse' AND (summary LIKE 'Edit:%' OR summary LIKE 'Write:%' OR summary LIKE 'MultiEdit:%'
                OR summary LIKE 'NotebookEdit:%'))) ORDER BY createdAt, id
                """, arguments: StatementArguments(ids))
            var summaries: [String: ProductSummary] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT unit, json FROM workSummary WHERE folder = ?", arguments: [folder]) {
                let json: String = row["json"]
                summaries[row["unit"]] = try? JSONDecoder().decode(ProductSummary.self, from: Data(json.utf8))
            }
            return (events, summaries)
        }) ?? ([], [:])
        var folderWork = work[folder] ?? Work.Folder()
        folderWork.runs = Runs.from(events)
        folderWork.summaries = summaries
        if work[folder] != folderWork { work[folder] = folderWork }
    }

    /// What a unit changed for the product's users, from its commits, the user's requests, Claude's answers and
    /// (for what isn't sent yet) the diff — one short `claude -p` on click, then kept.
    func explain(_ unit: Work.Unit, in folder: String, repo: Work.Repo?) async throws {
        guard let login = loginEnvironment else { throw ClaudeHeadless.Failure(errorDescription: "claude isn't found in the login shell") }
        explainingUnits.insert(unit.key)
        defer { explainingUnits.remove(unit.key) }
        let material = await Task.detached { Work.material(of: unit, in: repo) }.value
        let prompt = Work.prompt(runs: unit.runs, commits: material.commits, diff: material.diff, language: GitPanel.userLanguage)
        let data = try await ClaudeHeadless.askJSON(prompt, schema: Work.schema, claude: login.claudePath, environment: login.environment)
        _ = try JSONDecoder().decode(ProductSummary.self, from: data)
        let json = String(decoding: data, as: UTF8.self)
        try await db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO workSummary (folder, unit, json, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [folder, unit.key, json, Date.now])
        }
        reloadRuns(folder)
    }

    /// A Bash step that may have committed or pushed: git is read again.
    nonisolated static func touchesGit(_ payload: HookPayload) -> Bool {
        guard payload.toolName == "Bash", let command = payload.toolTarget else { return false }
        return ["git push", "git commit", "gh pr"].contains { command.contains($0) }
    }

    /// Per session: its latest step in plain words, for Home. Never "Session started" or "Session ended".
    private(set) var lastLine: [Int64: EventStory.Line] = [:]
    /// Not a step: the session starting or ending, and the Notification that echoes a permission request or a
    /// question ~6 s later ("Waiting for you") — it would hide what the session waits on.
    private static let notALastLine: Set = ["SessionStart", "SessionEnd", "Notification"]

    private func reloadLastLines() {
        var result: [Int64: EventStory.Line] = [:]
        try? db.read { db in
            for id in sessions.compactMap(\.id) {
                let recent = try HookEvent.fetchAll(db, sql: """
                    SELECT * FROM hookEvent WHERE sessionId = ? AND name NOT IN ('SessionStart', 'SessionEnd', 'Notification')
                    ORDER BY createdAt DESC, id DESC LIMIT 20
                    """, arguments: [id])
                result[id] = recent.lazy.compactMap(EventStory.line(for:)).first
            }
        }
        lastLine = result
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
        /// A chain that was a button in meepo 0.3, switched off in 0.4 (meepo no longer types into terminals).
        var retired: Bool?
    }

    private static let suggestionsKey = "suggestionStates"

    private(set) var suggestionStates: [String: SuggestionState] = [:]
    /// Everything noticed in history, newest reading; `visibleSuggestions` filters what the user already answered.
    private(set) var suggestions: [Noticing.Suggestion] = []

    /// Old 0.3 buttons first — shown even when history no longer counts them as a habit — then what was noticed.
    var visibleSuggestions: [Noticing.Suggestion] {
        let retired = suggestionStates.filter { $0.key.hasPrefix("chain:") && $0.value.retired == true }.keys.sorted()
            .map { key in
                suggestions.first { $0.id == key }
                    ?? Noticing.Suggestion(kind: .chain(key.dropFirst(6).components(separatedBy: ">")), count: 0)
            }
        return (retired + suggestions.filter { suggestionStates[$0.id]?.retired != true }).filter { suggestion in
            let state = suggestionStates[suggestion.id]
            guard state?.appliedAt == nil else { return false }
            return state?.dismissedAt.map { suggestion.count >= 2 * $0 } ?? true
        }
    }

    func isRetired(_ suggestion: Noticing.Suggestion) -> Bool { suggestionStates[suggestion.id]?.retired == true }

    /// Reads history.jsonl off the main thread and finds chains and repeated requests.
    func refreshSuggestions() async {
        let known = Set(commandsByProject.values.flatMap { $0.map(\.name) } + CommandCatalog.builtIns.map(\.name))
        suggestions = await Task.detached {
            let text = (try? String(contentsOf: Automations.historyFile, encoding: .utf8)) ?? ""
            let entries = Noticing.entries(historyLines: text.split(separator: "\n"))
            let since = Date.now.addingTimeInterval(-Noticing.window)
            return Noticing.chains(entries, known: known, since: since) + Noticing.repeatedPrompts(entries, since: since)
        }.value + usageSuggestions()
    }

    /// Panels in the layout and stages on the bar not used once in `UsageCounts.quietDays` (counting on that long).
    func usageSuggestions(now: Date = .now) -> [Noticing.Suggestion] {
        guard learnsUsage else { return [] }
        let (counts, first) = UsageCounts.totals(since: now.addingTimeInterval(-Double(UsageCounts.quietDays) * 86400), in: db)
        let panels = ShellLayout.Zone.allCases.flatMap { shell[$0] }.map { "panel." + $0.rawValue }
        let stageNames = stages.map { "stage." + $0.name }
        return UsageCounts.unused(panels + stageNames, counts: counts, firstDay: first, now: now).map { name in
            let item = String(name.drop { $0 != "." }.dropFirst())
            return Noticing.Suggestion(kind: name.hasPrefix("panel.") ? .unusedPanel(item) : .unusedStage(item),
                                       count: UsageCounts.quietDays)
        }
    }

    /// "Hide it" on an unused panel or stage; comes back from Edit stages / the rail, like any hidden one.
    func hideUnused(_ suggestion: Noticing.Suggestion) {
        switch suggestion.kind {
        case let .unusedPanel(raw): if let panel = ShellLayout.Panel(rawValue: raw) { editShell { $0.remove(panel) } }
        case let .unusedStage(name): stages.removeAll { $0.name == name }
        default: return
        }
        markApplied(suggestion)
    }

    /// Once: the bar keeps only the stages actually used (history, 8 weeks, plus meepo's own counts); the rest go,
    /// with a note that says which and puts them back on request. Seven equal buttons read as noise.
    func tidyStagesOnce() async {
        let key = "stagesTidied"
        guard !isDemo, !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        var usage = await Task.detached {
            let text = (try? String(contentsOf: Automations.historyFile, encoding: .utf8)) ?? ""
            return Automations.usage(historyLines: text.split(separator: "\n")).mapValues(\.total)
        }.value
        let clicks = UsageCounts.totals(since: .now.addingTimeInterval(-Double(Automations.weeks) * 7 * 86400), in: db).counts
        for (name, count) in clicks where name.hasPrefix("stage.") {
            if let command = stages.first(where: { "stage." + $0.name == name })?.command { usage[command, default: 0] += count }
        }
        let before = stages
        let kept = Stage.used(before, usage: usage)
        let hidden = before.filter { !kept.contains($0) }
        guard !hidden.isEmpty, kept.count > 1 else { return }
        stages = kept
        confirmation = PixelConfirmation(
            title: "A shorter bar",
            message: "Hidden, as you haven't used them in 8 weeks: \(hidden.map(\.label).joined(separator: ", ")). They're one click away in MORE, and Edit stages (right-click a stage) puts them back.\n\nThe button to press next now lights up: SIMP once Claude has changed code, then SHIP, then SYNC.",
            action: "OK", alternative: ("PUT THEM BACK", { [weak self] in self?.stages = before }), cancel: nil, isDestructive: false
        ) {}
    }

    /// MORE → Pin to the bar: any command as a button next to the stages (e.g. /starting-session).
    func pinCommand(_ name: String) {
        guard !skillButtons.contains(name) else { return }
        skillButtons.append(name)
        defaults.set(skillButtons, forKey: Self.skillButtonsKey)
    }

    func dismissSuggestion(_ suggestion: Noticing.Suggestion) {
        // An old 0.3 button is told about once; it comes back only as a habit (a retired one may count 0).
        suggestionStates[suggestion.id, default: SuggestionState()].dismissedAt = max(suggestion.count, Noticing.threshold)
        suggestionStates[suggestion.id]?.retired = nil
        saveSuggestionStates()
    }

    func markApplied(_ suggestion: Noticing.Suggestion) {
        suggestionStates[suggestion.id, default: SuggestionState()].appliedAt = .now
        suggestionStates[suggestion.id]?.retired = nil // made again: from now on it's a button like any other
        saveSuggestionStates()
    }

    /// Before 0.4 meepo typed a chain's commands itself (a "Chain paused" banner and all). 0.4 switched those
    /// buttons off; each comes back as "your button from 0.3 — make it again" until it's a skill of the user's.
    /// Chains that only left a run count behind ("chainRuns") were buttons too.
    private static func retireChains(from defaults: UserDefaults) {
        let chains = defaults.data(forKey: "chains").flatMap { try? JSONDecoder().decode([[String]].self, from: $0) } ?? []
        let ran = (defaults.dictionary(forKey: "chainRuns") ?? [:]).keys.map { $0.components(separatedBy: ">") }
        guard defaults.object(forKey: "chains") != nil || defaults.object(forKey: "chainRuns") != nil else { return }
        var states = load([String: SuggestionState].self, suggestionsKey, from: defaults) ?? [:]
        let buttons = Set(defaults.stringArray(forKey: skillButtonsKey) ?? [])
        for chain in chains + ran where chain.count > 1 && !buttons.contains(Recipes.buttonName(for: chain)) {
            let key = "chain:" + chain.joined(separator: ">")
            states[key, default: SuggestionState()].retired = true
            states[key]?.appliedAt = nil
        }
        defaults.set(try? JSONEncoder().encode(states), forKey: suggestionsKey)
        defaults.removeObject(forKey: "chains")
        defaults.removeObject(forKey: "chainRuns")
    }

    private func saveSuggestionStates() {
        defaults.set(try? JSONEncoder().encode(suggestionStates), forKey: Self.suggestionsKey)
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
        let file = try writeSkill(named: name) { _ in text }
        markApplied(suggestion)
        return file
    }

    /// A new personal skill, logged in Tools → Changes. `text` gets the final name (latin letters, digits, hyphens).
    /// Never a name Claude Code or any of the user's projects already answers to: yours would replace it.
    private func writeSkill(named name: String, text: (String) -> String) throws -> URL {
        let slug = ClaudeLauncher.worktreeSlug(name)
        if let problem = Recipes.nameProblem(slug, taken: commandNames) { throw ClaudeHeadless.Failure(errorDescription: problem) }
        let file = skillFile(slug)
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw ClaudeHeadless.Failure(errorDescription: "You already have a skill called \(slug)")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text(slug).write(to: file, atomically: true, encoding: .utf8)
        ChangeLog.record("New skill /\(slug)", file: file, backup: nil, backups: backupsDir)
        refreshProjects()
        return file
    }

    var claudeHome: URL { bridge.settingsURL.deletingLastPathComponent() }
    private func skillFile(_ name: String) -> URL { claudeHome.appending(path: "skills/\(name)/SKILL.md") }

    /// Every /name the user has, their own or a project's.
    var commandNames: Set<String> { Set(commandsByProject.values.flatMap { $0.map(\.name) }) }

    /// "New command…": a personal skill Claude may start too — or it couldn't be a workflow step. Returns its name.
    @discardableResult
    func makeCommand(named name: String, instructions: String) throws -> String {
        let file = try writeSkill(named: name) { Recipes.command(name: $0, instructions: instructions) }
        return file.deletingLastPathComponent().lastPathComponent
    }

    // MARK: Workflows — the constructor writes Claude Code files (Recipes), meepo only starts them

    private static let skillButtonsKey = "skillButtons"
    /// The image paste in progress (Drops): the next one waits for it and its clipboard restore.
    var pasting: Task<Void, Never>?
    /// Personal skills shown as buttons next to the stages, in the order they were made.
    private(set) var skillButtons: [String] = []
    /// Each button's steps, read with the project commands — so body never reads a file.
    private var buttonSteps: [String: [Recipes.Step]] = [:]
    /// Claude Code's saved workflows each project can run (~/.claude/workflows and the project's own).
    private(set) var workflowsByProject: [Int64: [Recipes.SavedWorkflow]] = [:]

    /// Writes the steps as a personal skill and pins it as a button. Returns the skill's name. A skill of that
    /// name with the same steps (a button removed earlier) is pinned again; one with other steps is never touched.
    @discardableResult
    func makeButton(named name: String, steps: [Recipes.Step]) throws -> String {
        let slug = ClaudeLauncher.worktreeSlug(name)
        let existing = slug.isEmpty ? nil : try? String(contentsOf: skillFile(slug), encoding: .utf8)
        if existing.map({ Recipes.steps(inSkill: $0) != steps }) ?? true {
            _ = try writeSkill(named: slug) { Recipes.skill(name: $0, steps: steps) }
        }
        if !skillButtons.contains(slug) { skillButtons.append(slug) }
        defaults.set(skillButtons, forKey: Self.skillButtonsKey)
        buttonSteps[slug] = steps
        // Commands in a row that meepo noticed (or a 0.3 button): the button is the answer, whatever its name.
        if let chain = Recipes.chain(of: steps) { markApplied(Noticing.Suggestion(kind: .chain(chain), count: 0)) }
        return slug
    }

    /// Unpins a button; the skill stays in ~/.claude/skills (Automations lists it; /name still runs it).
    func removeButton(_ name: String) {
        skillButtons.removeAll { $0 == name }
        defaults.set(skillButtons, forKey: Self.skillButtonsKey)
        // A button that runs commands in a row ("chain:simplify>ship"): it becomes a suggestion again.
        let steps = (try? String(contentsOf: skillFile(name), encoding: .utf8)).map(Recipes.steps(inSkill:)) ?? []
        if let chain = Recipes.chain(of: steps) {
            suggestionStates["chain:" + chain.joined(separator: ">")]?.appliedAt = nil
            saveSuggestionStates()
        }
    }

    /// Buttons this project can run: the skill still exists, and so does every command it runs
    /// (a /simplify → /sync button has nothing to do where there's no /sync).
    func skillButtons(for projectId: Int64) -> [String] {
        let names = Set((commandsByProject[projectId] ?? []).map(\.name))
        return skillButtons.filter { names.contains($0) && Recipes.canRun(buttonSteps[$0] ?? [], with: names) }
    }

    /// "Make a button" on a noticed chain: a skill named after its commands.
    func makeButton(from suggestion: Noticing.Suggestion) throws {
        guard case let .chain(commands) = suggestion.kind else { return }
        try makeButton(named: Recipes.buttonName(for: commands), steps: commands.map(Recipes.Step.command))
    }

    /// Repeats a button's skill in this session while it stays open (Claude Code's /loop).
    func repeatButton(_ name: String, every minutes: Int, in sessionId: Int64) {
        type(Recipes.loopCommand(skill: name, minutes: minutes) + "\r", into: sessionId)
    }

    /// Asks Claude Code's /schedule for a cloud routine with the button's steps written out.
    func scheduleButton(_ name: String, when: String, in sessionId: Int64) throws {
        let steps = Recipes.steps(inSkill: try String(contentsOf: skillFile(name), encoding: .utf8))
        guard !steps.isEmpty else {
            throw ClaudeHeadless.Failure(errorDescription: "/\(name) isn't a numbered list of steps any more — schedule it in Claude Code with /schedule")
        }
        type(Recipes.scheduleRequest(steps: steps, when: when) + "\r", into: sessionId)
    }

    func runWorkflow(_ workflow: Recipes.SavedWorkflow, in sessionId: Int64) {
        type(Recipes.runRequest(workflow) + "\r", into: sessionId)
    }

    /// Checks after every answer: in one project's own `.claude/settings.local.json` (nil: every project, in
    /// ~/.claude/settings.json).
    func checks(in project: Project?) -> [String] {
        Recipes.checks(in: (try? settings(for: project).readSettings()) ?? [:])
    }

    func addCheck(_ check: String, in project: Project?) throws {
        try editChecks("Check after every answer: \(check)", project) { Recipes.addingCheck(check, to: $0) }
    }

    func removeCheck(_ check: String, in project: Project?) throws {
        try editChecks("Remove check: \(check)", project) { Recipes.removingCheck(check, from: $0) }
    }

    private func editChecks(_ action: String, _ project: Project?, _ change: @escaping ([String: Any]) -> [String: Any]) throws {
        try settings(for: project).editSettings(action) { $0 = change($0) }
        // A personal file stays personal: the repo's own exclude file, never committed.
        if let project { GitService.ignoreLocally(".claude/settings.local.json", in: project.path, backups: backupsDir) }
    }

    /// The settings file checks live in: the project's own local one, or ~/.claude/settings.json for every project.
    private func settings(for project: Project?) -> BridgeInstaller {
        guard let project else { return bridge }
        var local = bridge
        local.settingsURL = URL(filePath: project.path).appending(path: ".claude/settings.local.json")
        return local
    }

    // MARK: Automations — the user's skills and commands, how they're used, their settings

    /// Built off the main thread: reads history.jsonl and asks git which project files are the team's.
    func automations() async -> [Automations.Item] {
        let projects = projects.map { (name: $0.name, path: $0.path) }
        let home = claudeHome, userHome = claudeHome.deletingLastPathComponent()
        return await Task.detached {
            let history = (try? String(contentsOf: Automations.historyFile, encoding: .utf8)) ?? ""
            let usage = Automations.usage(historyLines: history.split(separator: "\n"))
            var items: [String: Automations.Item] = [:]
            var seenFiles: Set<String> = []
            func add(_ command: SlashCommand, project: (name: String, path: String)?) {
                let isFirst = items[command.name] == nil
                var item = items[command.name] ?? Automations.Item(
                    name: command.name, description: command.description, personalFiles: [], teamFiles: [],
                    owner: .builtIn, projects: [],
                    usage: usage[command.name] ?? Automations.Usage(weekly: Array(repeating: 0, count: Automations.weeks), lastUsed: nil))
                if let project, !item.projects.contains(project.name) { item.projects.append(project.name) }
                // Only you when every copy /name runs is: a project's own plan.md is one Claude may start, even
                // where other projects get Claude Code's /plan screen.
                item.isUserOnly = (isFirst || item.isUserOnly) && command.isUserOnly
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
                for command in CommandCatalog.commands(projectPath: home.path, home: userHome) { add(command, project: nil) }
            }
            for project in projects {
                for command in CommandCatalog.commands(projectPath: project.path, home: userHome) {
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
        sessions = (try? db.read { try Session.order(Column("createdAt"), Column("id")).fetchAll($0) }) ?? []
        servers = (try? db.read { try Server.order(Column("label"), Column("host")).fetchAll($0) }) ?? []
        databases = (try? db.read { try ProjectDatabase.order(Column("label")).fetchAll($0) }) ?? []
    }

    // MARK: Hook events

    var waitingCount: Int {
        sessions.filter { $0.status == .waitingInput || $0.status == .waitingPermission }.count
            + elsewhere.filter(\.needsYou).count
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
        if payload.event == "UserPromptSubmit" { holds[sessionId] = nil } // what was said reached claude
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
        if payload.event == "SessionStart", payload.claudeSessionId != session.claudeSessionId {
            if session.agentId != nil { markAttached(session, false) }
            session.claudeSessionId = payload.claudeSessionId
            if session.agentId != nil { markAttached(session) }
        }
        if let stage = nextStage(after: session.stage, for: payload) { session.stage = stage }
        let todos = payload.todoLines.map {
            AgentTodo(projectId: session.projectId, file: payload.toolTarget ?? "", line: $0, createdAt: .now)
        }
        // A Notification is a delayed echo (~6 s) of a prompt already reported by PermissionRequest;
        // it must not turn a question (waiting for input) into a permission request.
        let isEcho = payload.event == "Notification" && (old == .waitingInput || old == .waitingPermission)
        if let status = payload.status, !isEcho { session.status = status }
        if payload.status != nil, payload.event != "Notification" { lastTurnEvents[sessionId] = payload.event }
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
        noteForHome(event, payload: payload, session: session)
        if payload.event == "Stop", payload.backgroundTasks == 0, relayingSessionIds.contains(sessionId) {
            finishRelay(sessionId, summary: payload.lastAssistantMessage)
            return nil
        }
        let attention = Attention.from(old, to: session.status)
        return payload.isQuestion && attention != nil ? .question : attention
    }

    /// Keeps Home and What changed current: the latest step, the name, the requests on a prompt or an answer,
    /// and git after an answer or a step that may have committed or pushed.
    private func noteForHome(_ event: HookEvent, payload: HookPayload, session: Session) {
        let id = session.id!
        if !Self.notALastLine.contains(event.name), let line = EventStory.line(for: event) { lastLine[id] = line }
        if payload.event == "UserPromptSubmit", titles[id] == nil, let typed = Runs.typed(payload.prompt ?? ""), !typed.isEmpty {
            titles[id] = typed
        }
        guard let folder = workdir(of: session) else { return }
        if ["UserPromptSubmit", "UserPromptExpansion", "Stop", "StopFailure", "SessionEnd"].contains(payload.event) { reloadRuns(folder) }
        if payload.event == "Stop" || (payload.event == "PostToolUse" && Self.touchesGit(payload)) {
            Task { await refreshWork(folder) }
        }
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

    private(set) var sessionUsage: [Int64: SessionUsage] = [:]
    private var isScanning = false

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// Only until Claude Code's first statusline, which says the window itself: the model's window, else 200K.
    func contextWindow(for model: String?) -> Int {
        model.map(Self.nativeWindow) ?? Self.defaultContextWindow
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

    /// "Opus 5.5 · xhigh", "· guided" when it runs in Guided mode: what the session really runs, once Claude Code
    /// has said; else what Meepo started it with.
    func modelLine(of session: Session) -> String {
        if let caption = session.shellCaption { return caption }
        let live = session.id.flatMap { liveStatus[$0] }
        let model = live?.modelName ?? session.model ?? "default model"
        let effort = live?.effort ?? session.effort
        let guided = session.id.map(guidedSessionIds.contains) == true ? "guided" : nil
        return [model, effort, guided].compactMap { $0 }.joined(separator: " · ")
    }

    func applyStatusLine(_ status: StatusLine, sessionId: Int64) {
        if liveStatus[sessionId] != status { liveStatus[sessionId] = status }
        if status.fiveHour != nil || status.sevenDay != nil,
           usageLimits?.fiveHour != status.fiveHour || usageLimits?.sevenDay != status.sevenDay {
            usageLimits = (status.fiveHour, status.sevenDay)
        }
    }

    /// 0…1 (can exceed 1 if meepo's guess of the window is too small); nil before the first response.
    func contextFraction(for sessionId: Int64) -> Double? {
        if let percent = liveStatus[sessionId]?.contextPercent { return percent / 100 } // Claude Code's own count
        guard let usage = sessionUsage[sessionId], usage.contextTokens > 0 else { return nil }
        return Double(usage.contextTokens) / Double(contextWindow(for: usage.model))
    }

    /// The context bar's tooltip: whose number it is — Claude Code's own, or meepo's estimate before its first statusline.
    func contextHelp(for sessionId: Int64) -> String {
        if let status = liveStatus[sessionId], let percent = status.contextPercent {
            var text = "Context \(Int(percent.rounded()))% full"
            if let size = status.contextWindow {
                text += " (of " + (size % 1_000_000 == 0 ? "\(size / 1_000_000)M" : TokenFormat.short(size)) + " tokens)"
            }
            return text + " — Claude Code's own count"
        }
        guard let fraction = contextFraction(for: sessionId) else { return "Context: no reply yet" }
        return "Context ≈\(Int((fraction * 100).rounded()))% — meepo's estimate until Claude Code reports"
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
    /// All Claude Code tokens on this Mac today, for the menu bar; refreshed with the widget's numbers so both agree.
    private(set) var usageToday = 0

    /// Hands the desktop widget its numbers; reloads it only when they change (WidgetKit budgets reloads).
    func publishWidgetSnapshot() {
        usageToday = usageStats(since: Calendar.current.startOfDay(for: .now)).total.total
        let next = WidgetSnapshot(tokensToday: usageToday,
                                  activeSessions: sessions.filter { $0.sshHost == nil && runningSessionIds.contains($0.id ?? -1) }.count, waitingSessions: waitingCount, updatedAt: .now)
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
    /// Leaves out "<synthetic>", which is no model (see `recentModels`).
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
            let byModel = try Row.fetchAll(db, sql: "SELECT model, \(sums) FROM usageRecord WHERE createdAt >= ? AND model NOT LIKE '<%' GROUP BY model",
                                           arguments: [start])
            stats.byModel = byModel.map { (name: $0["model"] as String, totals: totals($0)) }
            var byProject: [String: UsageTotals] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT cwd, \(sums) FROM usageRecord WHERE createdAt >= ? AND model NOT LIKE '<%' GROUP BY cwd",
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

    /// The oldest response meepo has counted: where "All time" starts. meepo keeps its counts, but Claude Code
    /// deletes a transcript after 30 days (cleanupPeriodDays), so whatever came before meepo's first scan is gone.
    func usageHistoryStart() -> Date? {
        try? db.read { try Date.fetchOne($0, sql: "SELECT MIN(createdAt) FROM usageRecord WHERE model NOT LIKE '<%'") }
    }

    /// Models seen in the last 30 days, for the stages' model menus.
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
    private static let editedLayoutsKey = "shellEdited"

    var shellPreset: ShellLayout.Preset {
        didSet { defaults.set(shellPreset.rawValue, forKey: Self.shellPresetKey) }
    }

    /// Each preset as the user changed it; a preset not here is as it comes.
    private(set) var editedLayouts: [ShellLayout.Preset: ShellLayout] = [:] {
        didSet {
            let byName = Dictionary(uniqueKeysWithValues: editedLayouts.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(byName), forKey: Self.editedLayoutsKey)
        }
    }

    /// What the window shows now: the current preset, with the user's changes.
    private(set) var shell: ShellLayout {
        didSet { defaults.set(try? JSONEncoder().encode(shell), forKey: Self.shellKey) }
    }

    /// The Home tab (Deck/Timeline) instead of a session; picking a session leaves it.
    var isHomeShown = false

    func applyPreset(_ preset: ShellLayout.Preset) {
        shellPreset = preset
        shell = editedLayouts[preset] ?? ShellLayout.preset(preset)
    }

    /// Moves, hides or opens panels by hand: the current preset keeps it — set up once, it stays that way.
    func editShell(_ change: (inout ShellLayout) -> Void) {
        var layout = shell
        change(&layout)
        guard layout != shell else { return }
        shell = layout
        editedLayouts[shellPreset] = layout == ShellLayout.preset(shellPreset) ? nil : layout
    }

    /// Back to the preset as it comes.
    func resetPreset(_ preset: ShellLayout.Preset) {
        editedLayouts[preset] = nil
        if shellPreset == preset { shell = ShellLayout.preset(preset) }
    }

    /// Before 0.4 a changed layout became a fourth preset, Custom. It becomes Full's own now (the closest to
    /// a hand-made VS Code-like arrangement), so nothing set up is lost.
    private static func retireCustomLayout(from defaults: UserDefaults) {
        if defaults.string(forKey: shellPresetKey) == "custom" { defaults.set(ShellLayout.Preset.full.rawValue, forKey: shellPresetKey) }
        guard let custom = defaults.data(forKey: "shellCustom") else { return }
        if defaults.data(forKey: editedLayoutsKey) == nil,
           let layout = try? JSONDecoder().decode(ShellLayout.self, from: custom),
           let data = try? JSONEncoder().encode([ShellLayout.Preset.full.rawValue: layout]) {
            defaults.set(data, forKey: editedLayoutsKey)
        }
        defaults.removeObject(forKey: "shellCustom")
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
        // All on screen: the grid reads like the tabs, left to right, top to bottom — never rotated to the anchor.
        if count >= ids.count { return ids }
        guard let anchorIndex = ids.firstIndex(of: anchor) else { return Array(ids.prefix(count)) }
        // Never wrapping from the last tab to the first: near the end the window slides back, so the last tab
        // shares the grid with the tabs just before it (its own project's), not with whatever tab comes first.
        let start = min(anchorIndex, ids.count - count)
        return Array(ids[start..<start + count])
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

    private static let remoteControlKey = "remoteControl"
    private static let shellsBesideKey = "shellsBeside"
    private static let learnsUsageKey = "learnsUsage"

    /// Settings → Learn from how I use meepo: local counts (UsageCounts) that Automations turns into suggestions.
    var learnsUsage: Bool {
        didSet { defaults.set(learnsUsage, forKey: Self.learnsUsageKey) }
    }

    /// One use of a part of meepo — a name, never what was in it.
    func count(_ name: String) {
        guard learnsUsage, !isDemo else { return }
        UsageCounts.add(name, in: db)
    }

    /// Settings → Forget: every count gone, and what they suggested.
    func forgetUsage() {
        UsageCounts.forget(in: db)
        suggestions.removeAll { if case .unusedPanel = $0.kind { true } else if case .unusedStage = $0.kind { true } else { false } }
    }
    private static let appearanceKey = "appearance"

    enum Appearance: String, CaseIterable {
        case system, light, dark

        var title: String { rawValue.capitalized }

        /// nil = follow macOS.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    /// Light, dark, or whatever macOS uses (and switches to at sunset). Applied to the whole app: every Tokens color
    /// resolves against it, terminals repaint (TerminalRegistry), and claude starts in the matching theme.
    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
            applyAppearance()
        }
    }

    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
        terminals.observeAppearance()
    }

    /// Sessions whose claude started in the dark theme: claude picks its colors once, when it starts.
    private(set) var darkSessionIds: Set<Int64> = []

    /// The terminals repainted; claude's own colors don't follow until it restarts — light-theme ink on a dark
    /// terminal is hard to read. Sessions between turns are offered a restart (the same conversation continues);
    /// busy ones keep their colors until the user restarts them.
    func appearanceChanged(dark: Bool) {
        guard !isDemo, confirmation == nil else { return }
        let offered = themeRestart(dark: dark)
        guard !offered.isEmpty else { return }
        let names = offered.compactMap { id in sessions.first { $0.id == id }.map(tabLabel) }.joined(separator: ", ")
        let count = offered.count == 1 ? "1 session" : "\(offered.count) sessions"
        confirmation = PixelConfirmation(
            title: dark ? "meepo is dark now" : "meepo is light now",
            message: "claude picks its colors when it starts, so \(names) still \(offered.count == 1 ? "uses" : "use") the \(dark ? "light" : "dark") theme. A restart continues the same conversation.",
            action: "Restart \(count)", cancel: "Later", isDestructive: false
        ) { [weak self] in
            guard let self else { return }
            for id in self.themeRestart(dark: dark) where offered.contains(id) { self.restartSession(id) }
        }
    }

    /// Running sessions in the other theme that are free to restart now (the Guided mode rule: between turns).
    private func themeRestart(dark: Bool) -> [Int64] {
        let states = turnStates.map { TurnState(id: $0.id, status: $0.status, lastEvent: $0.lastEvent,
                                                runsGuided: darkSessionIds.contains($0.id)) }
        return Self.guidedRestart(states, guided: dark, hooks: isBridgeInstalled).now
    }

    /// Server shells open next to the selected session, two terminals side by side (like VS Code's terminal under
    /// the editor); off = a tab of their own.
    var shellsBeside: Bool {
        didSet { defaults.set(shellsBeside, forKey: Self.shellsBesideKey) }
    }
    private static let shotHotKeyKey = "screenshotHotKey"

    /// Global screenshot hotkey (a `GlobalHotKey.combos` title); "" = off.
    var screenshotHotKey: String {
        didSet { defaults.set(screenshotHotKey, forKey: Self.shotHotKeyKey) }
    }

    /// Start sessions with Claude Code's Remote Control (phone app / claude.ai). Off by default:
    /// it needs a claude.ai login and shares the session with the user's Claude account.
    var remoteControlForNewSessions: Bool {
        didSet { defaults.set(remoteControlForNewSessions, forKey: Self.remoteControlKey) }
    }

    // MARK: Voice (Claude Code's /voice)

    private static let voiceHintKey = "voiceHintShown"
    /// Claude Code's voice dictation, as ~/.claude/settings.json has it — re-read every 10 s, so /voice typed in
    /// a session shows on the button too.
    private(set) var isVoiceOn = false
    /// Claude Code's voice mode as the settings file has it ("hold" or "tap").
    private(set) var voiceMode = "hold"
    /// Sessions where SPEAK was pressed and STOP not yet: Claude Code is listening there. A request reaching
    /// claude (Space pressed by hand, autoSubmit), a question from Claude, the session ending or 3 minutes end it.
    var listeningSessionIds: Set<Int64> { Set(holds.keys) }
    /// Each hold's number: a loop left over from an earlier SPEAK sees another number and quits.
    private var holds: [Int64: Int] = [:]
    @ObservationIgnored private var holdCount = 0
    /// Where typed keys go instead of the terminal — tests only.
    @ObservationIgnored var keySink: ((String, Int64) -> Void)?
    /// Demo mode: nothing of the user's is written; voice and Guided mode change only in memory.
    private var isDemo = false

    func refreshVoice() {
        guard !isDemo else { return }
        let settings = (try? bridge.readSettings()) ?? [:]
        let on = Voice.isOn(settings), mode = Voice.mode(settings)
        if on != isVoiceOn { isVoiceOn = on }
        if mode != voiceMode { voiceMode = mode }
        if !on { holds = [:] }
    }

    /// SPEAK / STOP: holds Space in the session while it listens (Claude Code's hold mode), lets go on STOP — the
    /// words stay in the prompt unsent, to fix or to add to with another SPEAK. Switches a tap-mode setup to hold.
    func speak(in sessionId: Int64) {
        if holds.removeValue(forKey: sessionId) != nil { return } // STOP: the loop below sees it and lets go
        refreshVoice()
        guard isVoiceOn, !exitedSessionIds.contains(sessionId) else { return }
        guard !isAwaitingAnswer(sessionId) else {
            bridgeError = "Claude is asking you something here — answer it first, then SPEAK."
            return
        }
        if voiceMode != "hold" {
            if !isDemo {
                do {
                    try bridge.editSettings("Voice: hold to talk") { Voice.setHold(in: &$0) }
                } catch {
                    bridgeError = error.localizedDescription
                    return
                }
            }
            voiceMode = "hold"
        }
        holdCount += 1
        let hold = holdCount
        holds[sessionId] = hold
        type(Voice.beforeHold, into: sessionId)
        Task { @MainActor [weak self] in
            // Space every 40 ms even with meepo in the background (no App Nap, no timer coalescing).
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                                 reason: "SPEAK holds Space")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let start = ContinuousClock.now
            var last = start
            while let self, self.holds[sessionId] == hold, !self.isAwaitingAnswer(sessionId),
                  ContinuousClock.now - start < Voice.holdLimit {
                // A stall this long (a busy main thread) and Claude Code has let go already: the next two Spaces
                // would be a double tap that sends. The words stay in the prompt; SPEAK again goes on.
                if ContinuousClock.now - last > Voice.letGo { break }
                last = .now
                self.type(Voice.holdKey, into: sessionId)
                try? await Task.sleep(for: Voice.holdRepeat)
            }
            if self?.holds[sessionId] == hold { self?.holds[sessionId] = nil }
        }
    }

    /// SEND: Enter in the session — what was said (and fixed) goes to Claude. Not while listening (the button is
    /// off then): the words land a moment after the let-go, and an Enter before them would send the prompt without.
    func sendSpoken(in sessionId: Int64) {
        guard holds[sessionId] == nil else { return }
        type("\r", into: sessionId)
    }

    /// VOICE: Claude Code's voice dictation on or off for every session, written the way /voice writes it —
    /// nothing is typed into a terminal. Turning it on asks macOS for the microphone first, on this click.
    /// True when the button should show how to use it: the first time voice is turned on here.
    func toggleVoice() async -> Bool {
        refreshVoice() // /voice typed in a session since the last 10 s read
        let on = !isVoiceOn
        if on, !isDemo {
            if Voice.microphone == .notAsked, !(await Voice.askForMicrophone()) { return false }
            guard Voice.microphone == .allowed else {
                confirmation = PixelConfirmation(
                    title: "MICROPHONE IS OFF FOR MEEPO",
                    message: "Claude Code runs inside meepo, so macOS asks meepo for the microphone — and it's off. Turn meepo on in System Settings → Privacy & Security → Microphone, then click VOICE again.",
                    action: "OPEN SYSTEM SETTINGS", isDestructive: false
                ) { Voice.openMicrophoneSettings() }
                return false
            }
        }
        if !isDemo {
            do {
                try bridge.editSettings(on ? "Voice on, tap to talk (/voice)" : "Voice off (/voice off)") {
                    Voice.set(on, in: &$0)
                    if on { Voice.setHold(in: &$0) }
                }
            } catch {
                bridgeError = error.localizedDescription
                return false
            }
        }
        isVoiceOn = on
        if on { voiceMode = "hold" } else { holds = [:] }
        guard on, !defaults.bool(forKey: Self.voiceHintKey) else { return false }
        defaults.set(true, forKey: Self.voiceHintKey)
        return true
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
        // What the user typed: a helper's report or a finished background task isn't a step forward.
        guard payload.event == "UserPromptSubmit", let typed = Runs.typed(payload.prompt ?? ""), !typed.hasPrefix("/"),
              let index = stages.firstIndex(where: { $0.name == current }),
              index + 1 < stages.count, stages[index + 1].command == nil else { return nil }
        return stages[index + 1].name
    }

    /// Types text into a session's terminal ("\r" = Enter). A line ending in Enter waits while Claude is asking
    /// something (a permission, or a question with choices): that Enter would pick the highlighted answer for the
    /// user. False when it wasn't typed.
    @discardableResult
    func type(_ text: String, into sessionId: Int64) -> Bool {
        if text.hasSuffix("\r"), isAwaitingAnswer(sessionId) {
            let name = sessions.first { $0.id == sessionId }.map(displayName(of:)) ?? "this session"
            bridgeError = "Claude is asking you something in \(name) — answer it first, then click again."
            return false
        }
        if let keySink { keySink(text, sessionId) } else { terminals.send(text, to: sessionId) }
        return true
    }

    /// Claude waits on the user's answer, not on a new request: a permission prompt, or AskUserQuestion (which comes
    /// in as a PermissionRequest too).
    func isAwaitingAnswer(_ sessionId: Int64) -> Bool {
        sessions.first { $0.id == sessionId }?.status == .waitingPermission || lastTurnEvents[sessionId] == "PermissionRequest"
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

    /// Other projects whose own, different /command a personal copy of `source`'s would replace: Claude Code reads
    /// ~/.claude/commands before a project's .claude/commands (a project's skill still wins over both).
    func projectsReplaced(byCopyOf command: String, from source: Project, excluding projectId: Int64) -> [Project] {
        let copy = URL(filePath: source.path).appending(path: ".claude/commands/\(command.replacingOccurrences(of: ":", with: "/")).md")
        return projects.filter { project in
            guard project.id != projectId, let own = (commandsByProject[project.id ?? -1] ?? []).first(where: { $0.name == command }),
                  let file = own.file, !own.isSkill, file.path.hasPrefix(project.path + "/") else { return false }
            return !FileManager.default.contentsEqual(atPath: file.path, andPath: copy.path)
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

    // MARK: DRAW — a diagram instead of text

    /// Sessions whose picture is being drawn.
    private(set) var drawingSessionIds: Set<Int64> = []

    func draw(_ request: Diagram.Request, for sessionId: Int64) async throws -> Diagram.Result {
        guard let login = loginEnvironment else { throw ClaudeHeadless.Failure(errorDescription: "claude isn't found in the login shell") }
        guard let session = sessions.first(where: { $0.id == sessionId }), let folder = workdir(of: session) else {
            throw ClaudeHeadless.Failure(errorDescription: "No such session.")
        }
        drawingSessionIds.insert(sessionId)
        defer { drawingSessionIds.remove(sessionId) }
        let material: String
        switch request {
        case .lastAnswer:
            guard let reply = latestReply(of: sessionId), !reply.isEmpty else {
                throw ClaudeHeadless.Failure(errorDescription: "Claude hasn't answered anything in this session yet.")
            }
            material = reply
        case .changes:
            let diff = await Task.detached { GitPanel.fullDiff(from: "HEAD", to: nil, in: folder) }.value
            guard !diff.isEmpty else { throw ClaudeHeadless.Failure(errorDescription: "Nothing uncommitted to draw.") }
            material = String(diff.prefix(Diagram.diffLimit))
        case .question:
            material = ""
        }
        let prompt = Diagram.prompt(request, material: material, language: GitPanel.userLanguage)
        let data = try await ClaudeHeadless.askJSON(prompt, schema: Diagram.schema, claude: login.claudePath, environment: login.environment,
                                                    tools: Diagram.tools(for: request), directory: URL(filePath: folder))
        let answer = try JSONDecoder().decode(Diagram.Result.self, from: data)
        count("draw")
        return Diagram.Result(title: answer.title, mermaid: Diagram.cleaned(answer.mermaid), caption: answer.caption)
    }

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
        let live = only ?? sessions.filter { $0.sshHost == nil && runningSessionIds.contains($0.id ?? -1) } // not server shells
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
        // A fetch or pull moves the upstream: what's sent and what isn't is read again.
        for path in byFolder.keys where !path.isEmpty { await refreshWork(path) }
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
            pipelines[projectId] = await Pipeline.titled(await provider.pipeline(runs: runs, in: project.path), in: project.path)
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
                    let logs = servers(of: projectId).contains { !$0.sources.isEmpty } ? " — Get server logs in the CI tab" : ""
                    onCINotice?("Deploy failed", "\(label): \(run.workflowName) — not fixed automatically\(logs)")
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

    /// A step is running or queued somewhere: CI is polled more often.
    var isCIRunning: Bool {
        pipelines.values.contains(where: \.isRunning) || repoCI.values.contains { $0.pipeline?.isRunning == true }
    }

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
            let pipeline = await Pipeline.titled(await provider.pipeline(runs: runs, in: repo.path), in: repo.path)
            repoCI[repo.path] = (latest.values.sorted { $0.createdAt > $1.createdAt }, pipeline)
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

    // MARK: Servers and logs (SPEC module 10)

    // MARK: Databases — Postgres for Claude, read only

    private(set) var databases: [ProjectDatabase] = []
    /// Each database's tables, read once (one query) and drawn from memory after.
    private(set) var schemas: [Int64: [Postgres.Table]] = [:]
    /// Runs psql; injected in tests so no real database is touched.
    var postgresRunner: Postgres.Runner = Postgres.run

    func databases(of projectId: Int64?) -> [ProjectDatabase] { databases.filter { $0.projectId == projectId } }

    /// psql from the login shell's PATH, else where Homebrew's keg-only formulas and Postgres.app keep it.
    var psqlPath: String? {
        toolPath("psql") ?? Postgres.kegPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// One of meepo's fixed queries, read only, off the main thread. `readOnly: false` only for the role SQL.
    func pgQuery(_ sql: String, url: String, readOnly: Bool = true) async -> Result<String, Postgres.Failure> {
        guard let psql = psqlPath else { return .failure(Postgres.notInstalled) }
        let runner = postgresRunner
        return await Task.detached { Postgres.query(sql, url: url, psql: psql, readOnly: readOnly, runner: runner) }.value
    }

    func identity(at url: String) async -> Result<Postgres.Identity, Postgres.Failure> {
        await pgQuery(Postgres.whoAmISQL, url: url).flatMap { output in
            Postgres.identity(from: output).map { .success($0) } ?? .failure(Postgres.Failure(errorDescription: "Unexpected answer: \(output)"))
        }
    }

    /// The Postgres containers on a server (docker ps / inspect over ssh, read only; the password stays there).
    func findDatabases(on serverId: Int64) async -> Result<[Postgres.Found], Postgres.Failure> {
        await runOnServer(serverId, Postgres.findOnServerCommand).map(Postgres.found(fromServerListing:))
    }

    /// One command on a project's server through the log-reading ssh (keys only, fails fast); its output or why not.
    private func runOnServer(_ serverId: Int64, _ command: String) async -> Result<String, Postgres.Failure> {
        guard let host = servers.first(where: { $0.id == serverId })?.host,
              let args = ServerLogs.sshArguments(host: host, command: command) else {
            return .failure(Postgres.Failure(errorDescription: "No such server."))
        }
        let runner = sshRunner
        let result = await Task.detached { runner(ServerLogs.ssh, args, ServerLogs.timeout) }.value
        guard result.status == 0 else {
            return .failure(Postgres.Failure(errorDescription: result.output.split(separator: "\n").last.map(String.init) ?? "ssh failed"))
        }
        return .success(result.output)
    }

    /// The whole setup for a database in Docker on a server, after the user said so: the read-only role made inside
    /// the container (docker exec, no password), a tunnel to it, a check that the role can't write, then Claude's
    /// .mcp.json gets it as its own server. Returns the database saved.
    @discardableResult
    func setUpOnServer(projectId: Int64, serverId: Int64, found: Postgres.Found, asksEachQuery: Bool = true,
                       progress: (String) -> Void = { _ in }) async throws -> ProjectDatabase {
        let password = Postgres.newPassword()
        guard let command = Postgres.createRoleCommand(in: found, sql: Postgres.roleSQL(database: found.database, password: password)) else {
            throw Postgres.Failure(errorDescription: "Unusual container or database name — set it up by hand.")
        }
        progress("Creating \(Postgres.role) inside \(found.container)…")
        if case let .failure(failure) = await runOnServer(serverId, command) { throw failure }
        progress("Opening the ssh tunnel…")
        guard let port = SSHTunnel.freePort() else { throw Postgres.Failure(errorDescription: "No free local port for the tunnel.") }
        let tunnel = Tunnel(serverId: serverId, remoteHost: found.ip, remotePort: 5432, localPort: port)
        guard openTunnel(Self.wizardTunnel, tunnel), await waitForTunnel(tunnel) else {
            closeTunnel(Self.wizardTunnel)
            throw Postgres.Failure(errorDescription: "The ssh tunnel didn't open.")
        }
        progress("Checking that \(Postgres.role) can only read…")
        let url = "postgresql://\(Postgres.role):\(password)@127.0.0.1:\(port)/\(found.database)"
        switch await identity(at: url) {
        case let .success(identity) where identity.user == Postgres.role && !identity.canWrite: break
        case .success: closeTunnel(Self.wizardTunnel); throw Postgres.Failure(errorDescription: "\(Postgres.role) can still change data — stopped before giving Claude access.")
        case let .failure(failure): closeTunnel(Self.wizardTunnel); throw failure
        }
        progress("Giving Claude access…")
        return try addDatabase(projectId: projectId, url: url, switchingFrom: url, tunnel: tunnel, asksEachQuery: asksEachQuery)
    }

    /// Runs the role SQL as the owner — the one write meepo ever makes, after the user saw the SQL and said so.
    func createReadOnlyRole(ownerURL: String, sql: String) async -> Result<Void, Postgres.Failure> {
        await pgQuery(sql, url: ownerURL, readOnly: false).map { _ in }
    }

    /// Where a database on a server is reached: through `localPort` to `remoteHost:remotePort` there.
    struct Tunnel: Equatable {
        let serverId: Int64
        let remoteHost: String
        let remotePort: Int
        let localPort: Int
    }

    /// Saves the database for the project. `switchingFrom`: Claude's postgres server in .mcp.json moves from that
    /// address to this one first (a backup, logged in Tools → Changes); nil keeps .mcp.json as it is. With a tunnel,
    /// meepo keeps it open from now on (it was opened for the wizard already).
    /// `asksEachQuery`: every query Claude makes shows its SQL and waits for Allow (production).
    @discardableResult
    func addDatabase(projectId: Int64, url: String, switchingFrom old: String?, tunnel: Tunnel? = nil,
                     asksEachQuery: Bool = false) throws -> ProjectDatabase {
        let label = Postgres.parts(of: url)?.database ?? "database"
        let serverLabel = tunnel.flatMap { tunnel in servers.first { $0.id == tunnel.serverId } }.map { $0.label.isEmpty ? $0.host : $0.label }
        var name = Postgres.mcpName(for: url, server: serverLabel)
        if let old { name = try switchClaude(projectId: projectId, from: old, to: url, name: name) }
        var database = ProjectDatabase(projectId: projectId, label: serverLabel.map { "\(label) on \($0)" } ?? label, url: url,
                                       serverId: tunnel?.serverId, remoteHost: tunnel?.remoteHost, remotePort: tunnel?.remotePort,
                                       localPort: tunnel?.localPort, mcpName: name, asksEachQuery: asksEachQuery)
        try db.write { try database.insert($0) }
        reload()
        if let tunnel, let id = database.id {
            closeTunnel(Self.wizardTunnel)
            _ = openTunnel(id, tunnel)
        }
        return database
    }

    /// Ask before each query, on or off, for sessions of the project started from now on.
    func setAsksEachQuery(_ database: ProjectDatabase, _ on: Bool) {
        var changed = database
        changed.asksEachQuery = on
        _ = try? db.write { try changed.update($0) }
        reload()
    }

    /// Permission rules a project's sessions start with: each asking database's MCP server, every tool of it.
    func databaseAsks(for projectId: Int64?) -> [String] {
        databases(of: projectId).filter(\.asksEachQuery).compactMap { $0.mcpName.map { "mcp__" + $0 } }
    }

    // MARK: Tunnels — ssh -L to databases on servers, open while meepo runs

    /// The Add database wizard's tunnel, before the database has an id.
    static let wizardTunnel: Int64 = -1
    private var tunnels: [Int64: Process] = [:]
    /// Tunnels to keep open: one that drops comes back after a few seconds.
    private var wantedTunnels: [Int64: Tunnel] = [:]

    /// Opens the tunnel (a running one is kept). False when it can't: no such server, or bad ports.
    @discardableResult
    func openTunnel(_ key: Int64, _ tunnel: Tunnel) -> Bool {
        wantedTunnels[key] = tunnel
        if tunnels[key]?.isRunning == true { return true }
        guard !isDemo, isLoginResolved, let host = servers.first(where: { $0.id == tunnel.serverId })?.host,
              let arguments = SSHTunnel.arguments(host: host, localPort: tunnel.localPort, remoteHost: tunnel.remoteHost,
                                                  remotePort: tunnel.remotePort) else { return false }
        let process = Process()
        process.executableURL = URL(filePath: ServerLogs.ssh)
        process.arguments = arguments
        process.environment = loginEnvironment?.environment ?? ClaudeLauncher.scrubbed(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self, self.tunnels[key] === ended else { return }
                self.tunnels[key] = nil
                try? await Task.sleep(for: .seconds(5))
                if let wanted = self.wantedTunnels[key] { self.openTunnel(key, wanted) }
            }
        }
        do { try process.run() } catch { return false }
        tunnels[key] = process
        return true
    }

    /// Waits until the tunnel's local port answers (a few seconds at most for ssh to log in).
    func waitForTunnel(_ tunnel: Tunnel) async -> Bool {
        for _ in 0..<50 {
            if !SSHTunnel.isFree(tunnel.localPort) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    func closeTunnel(_ key: Int64) {
        wantedTunnels[key] = nil
        tunnels.removeValue(forKey: key)?.terminate()
    }

    /// At launch: every saved database on a server gets its tunnel back.
    func openDatabaseTunnels() {
        for database in databases {
            guard let id = database.id, let serverId = database.serverId, let remoteHost = database.remoteHost,
                  let remotePort = database.remotePort, let localPort = database.localPort else { continue }
            openTunnel(id, Tunnel(serverId: serverId, remoteHost: remoteHost, remotePort: remotePort, localPort: localPort))
        }
    }

    /// When meepo quits: no ssh left behind.
    func closeTunnels() {
        wantedTunnels.removeAll()
        for process in tunnels.values { process.terminate() }
        tunnels.removeAll()
    }

    /// meepo forgets the database and closes its tunnel; its server leaves the project's .mcp.json too (a backup,
    /// logged in Tools → Changes), so Claude doesn't keep a database that's gone. The role stays in the database.
    func deleteDatabase(_ id: Int64) {
        if let database = databases.first(where: { $0.id == id }), let name = database.mcpName,
           let project = projects.first(where: { $0.id == database.projectId }) {
            let file = URL(filePath: project.path).appending(path: ".mcp.json")
            if let text = try? String(contentsOf: file, encoding: .utf8), let updated = Postgres.mcpConfig(text, removing: name),
               let backup = try? ChangeLog.backup(file, folder: "mcp", backups: backupsDir) {
                try? updated.write(to: file, atomically: true, encoding: .utf8)
                ChangeLog.record("Claude no longer reads \(database.label) (\(name))", file: file, backup: backup, backups: backupsDir)
            }
        }
        closeTunnel(id)
        _ = try? db.write { try ProjectDatabase.deleteOne($0, id: id) }
        schemas[id] = nil
        reload()
    }

    /// Points Claude's postgres MCP server in the project's .mcp.json at the read-only role. Claude reads it when a
    /// session starts.
    /// Returns the server's name in .mcp.json (the one switched, or the one added).
    private func switchClaude(projectId: Int64, from ownerURL: String, to roleURL: String, name: String) throws -> String {
        guard let project = projects.first(where: { $0.id == projectId }) else { throw Postgres.Failure(errorDescription: "No such project.") }
        let file = URL(filePath: project.path).appending(path: ".mcp.json")
        let old = try? String(contentsOf: file, encoding: .utf8)
        guard let updated = Postgres.mcpConfig(old, replacing: ownerURL, with: roleURL, name: name) else {
            throw Postgres.Failure(errorDescription: ".mcp.json isn't JSON meepo can read — change the postgres address there by hand.")
        }
        let backup = old == nil ? nil : try ChangeLog.backup(file, folder: "mcp", backups: backupsDir)
        try updated.text.write(to: file, atomically: true, encoding: .utf8)
        ChangeLog.record("Claude reads \(project.name)'s database as \(Postgres.role)", file: file, backup: backup, backups: backupsDir)
        return updated.key
    }

    /// The schema, from memory when read before (`refresh` reads it again).
    func schema(of database: ProjectDatabase, refresh: Bool = false) async -> Result<[Postgres.Table], Postgres.Failure> {
        if !refresh, let id = database.id, let cached = schemas[id] { return .success(cached) }
        let json = await pgQuery(Postgres.schemaSQL, url: database.url)
        // Decoded off the main thread: a few hundred tables with every column.
        let result = await Task.detached {
            json.flatMap { Postgres.tables(fromJSON: $0).map { .success($0) } ?? .failure(Postgres.Failure(errorDescription: "Couldn't read the schema.")) }
        }.value
        if case let .success(tables) = result, let id = database.id { schemas[id] = tables }
        return result
    }

    /// Servers of every project; ssh logs in with the user's own keys, meepo stores none.
    private(set) var servers: [Server] = []
    /// Runs ssh; injected in tests so no real ssh ever runs.
    @ObservationIgnored var sshRunner: ServerLogs.Runner = ServerLogs.runProcess

    func servers(of projectId: Int64?) -> [Server] {
        servers.filter { $0.projectId == projectId }
    }

    /// Adds or updates a server. Only a valid host and log sources the templates accept are kept.
    func saveServer(_ server: Server) throws {
        guard ServerLogs.isValidHost(server.host) else { throw ServerError.badHost(server.host) }
        if let bad = server.sources.first(where: { !ServerLogs.isValid($0) }) { throw ServerError.badSource(bad.name) }
        var saved = server
        try db.write { try saved.save($0) }
        reload()
    }

    func deleteServer(_ id: Int64) {
        _ = try? db.write { try Server.deleteOne($0, id: id) }
        reload()
    }

    enum ServerError: LocalizedError, Equatable {
        case badHost(String), badSource(String)

        var errorDescription: String? {
            switch self {
            case .badHost(let host): "“\(host)” isn't an ssh address — paste it as you'd type it: ssh root@1.2.3.4, or ssh -p 2222 user@host. Keys (-i) and jump hosts (-J) go in ~/.ssh/config."
            case .badSource(let name): "“\(name)” can't be passed safely: letters, digits and . _ - @ : only (a file path starts with / and may have /)."
            }
        }
    }

    /// Each source through its read-only template, off the main thread.
    func fetchLogs(_ picks: [(host: String, source: LogSource)]) async -> [ServerLogs.Fetched] {
        let runner = sshRunner
        let pairs = picks.map { ($0.host, $0.source) }
        return await Task.detached { pairs.map { ServerLogs.fetch($0.1, from: $0.0, runner: runner) } }.value
    }

    func listContainers(on host: String) async -> Result<[String], ServerLogs.ListError> {
        let runner = sshRunner
        return await Task.detached { ServerLogs.containers(on: host, runner: runner) }.value
    }

    /// Where logs go: the selected session when it's the project's and running, else its latest running one.
    func logsTarget(in projectId: Int64) -> Session? {
        // Never a server shell: pasted logs there would run as commands.
        if let selected = selectedSession, selected.projectId == projectId, selected.sshHost == nil, let id = selected.id,
           runningSessionIds.contains(id) {
            return selected
        }
        return sessions.last { $0.projectId == projectId && $0.sshHost == nil && $0.id.map(runningSessionIds.contains) == true }
    }

    /// Pastes the logs into the session's prompt; the user adds a question and sends it.
    func pasteLogs(_ fetched: [ServerLogs.Fetched], into sessionId: Int64) {
        guard type(ServerLogs.paste(fetched), into: sessionId) else { return }
        selectedSessionId = sessionId
    }

    /// A new session in the project that starts by investigating the logs.
    func investigateLogs(_ fetched: [ServerLogs.Fetched], in projectId: Int64, why: String? = nil) throws {
        try createSession(projectId: projectId, model: nil, prompt: ServerLogs.investigatePrompt(fetched, why: why),
                          name: "logs \(fetched.first?.host ?? "")")
    }

    /// A failed deploy: every log source of the project's servers → a new session investigating them.
    func investigateDeploy(_ run: CIRun, in project: Project) async {
        guard let projectId = project.id else { return }
        let picks = servers(of: projectId).flatMap { server in server.sources.map { (host: server.host, source: $0) } }
        guard !picks.isEmpty else { return }
        let fetched = await fetchLogs(picks)
        do {
            try investigateLogs(fetched, in: projectId,
                                why: "Deploy “\(run.workflowName)” failed on \(run.headBranch) @ \(run.headSha.prefix(7)) (\(run.url)).")
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

    /// The default branch's pipeline of a repo: its project's, or one inside a project folder / "Also work in".
    func pipeline(forRepo path: String) -> Pipeline? {
        if let project = projects.first(where: { $0.path == path }), let id = project.id { return pipelines[id] }
        return repoCI[path]?.pipeline
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
        var busy = Set(sessions.filter { $0.sshHost == nil }.map(\.projectId)) // a server shell edits no files here
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
    /// `commits`: each project's commits of the day by path, read off the main thread by the caller; nil = read here.
    func daySummary(now: Date = .now, commits: [String: [String]]? = nil) -> [ProjectDay] {
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
                commits: commits?[project.path] ?? GitService.commits(since: start, in: project.path),
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
        var workflows: [Int64: [Recipes.SavedWorkflow]] = [:]
        let ownWorkflows = Recipes.savedWorkflows(in: [claudeHome.appending(path: "workflows")])
        var dirty: Set<Int64> = []
        let home = claudeHome.deletingLastPathComponent() // where meepo writes the user's skills, so it reads them there too
        for project in projects {
            guard let id = project.id else { continue }
            commands[id] = CommandCatalog.commands(projectPath: project.path, home: home)
            workflows[id] = ownWorkflows + Recipes.savedWorkflows(in: [URL(filePath: project.path).appending(path: ".claude/workflows")])
            if GitService.hasUncommittedChanges(in: project.path) { dirty.insert(id) }
        }
        commandsByProject = commands
        workflowsByProject = workflows
        dirtyProjectIds = dirty
        buttonSteps = Dictionary(uniqueKeysWithValues: skillButtons.map { name in
            (name, (try? String(contentsOf: skillFile(name), encoding: .utf8)).map(Recipes.steps(inSkill:)) ?? [])
        })
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
    /// Tabs left to right. By project, oldest first, until the user drags a tab; then their order, and a session
    /// not in it yet (new since) goes last, so the arranged tabs and grid stay put — except a shell, which comes
    /// right after the one before it in the project order: the session it was opened beside.
    var orderedSessions: [Session] {
        let base = projects.flatMap { project in sessions.filter { $0.projectId == project.id } }
        guard !tabOrder.isEmpty else { return base }
        let rank = Dictionary(tabOrder.enumerated().map { ($1, $0) }) { first, _ in first }
        var ordered = base.filter { rank[$0.id ?? -1] != nil }.sorted { rank[$0.id!]! < rank[$1.id!]! }
        for (index, session) in base.enumerated() where rank[session.id ?? -1] == nil {
            guard session.sshHost != nil else { ordered.append(session); continue }
            let before = base[..<index].last { previous in ordered.contains { $0.id == previous.id } }
            let at = before.flatMap { previous in ordered.firstIndex { $0.id == previous.id } }.map { $0 + 1 } ?? 0
            ordered.insert(session, at: at)
        }
        return ordered
    }

    private static let tabOrderKey = "tabOrder"

    /// Session ids in the order the user dragged the tabs into; empty = never dragged. Closed ids are simply skipped.
    private var tabOrder: [Int64] {
        didSet { defaults.set(tabOrder, forKey: Self.tabOrderKey) }
    }

    /// A tab dropped on another: it takes that tab's place, pushing it right (or left, when dragged from its left).
    func moveTab(_ id: Int64, onto target: Int64) {
        var ids = orderedSessions.compactMap(\.id)
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        tabOrder = ids
    }

    /// Closed this run, still holding their place in `tabOrder`: closed id → its project.
    private var vacatedSlots: [Int64: Int64] = [:]

    /// A new session of a project whose tab was just closed takes that tab's place — closing taxinet and opening a
    /// fresh one doesn't send it to the end and move the other panes.
    private func takeVacatedSlot(_ id: Int64?, projectId: Int64) {
        guard let id, let index = tabOrder.lastIndex(where: { vacatedSlots[$0] == projectId }) else { return }
        vacatedSlots[tabOrder[index]] = nil
        tabOrder[index] = id
    }

    /// A terminal pane dropped on another by its header: the two trade places, in the grid and in the tabs.
    func swapTabs(_ id: Int64, _ other: Int64) {
        var ids = orderedSessions.compactMap(\.id)
        guard id != other, let a = ids.firstIndex(of: id), let b = ids.firstIndex(of: other) else { return }
        ids.swapAt(a, b)
        tabOrder = ids
        // The grid starts at the anchor: it moves with its slot, so the other panes stay where they were.
        if paneAnchor == id { paneAnchor = other } else if paneAnchor == other { paneAnchor = id }
    }

    /// What a dragged tab or pane header carries; panels drag their own names, so it's told apart by the prefix.
    static let tabDragPrefix = "meepo-tab:"

    static func draggedTab(_ items: [String]) -> Int64? {
        items.first.flatMap { $0.hasPrefix(tabDragPrefix) ? Int64($0.dropFirst(tabDragPrefix.count)) : nil }
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
                       worktree: String? = nil, resuming: String? = nil, name: String? = nil, extraDirs: [String] = [],
                       agentId: String? = nil, folder: String? = nil) throws {
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
            extraDirs: extraDirs.isEmpty ? nil : extraDirs,
            agentId: agentId,
            folder: folder == project.path ? nil : folder
        )
        try db.write { try session.insert($0) }
        takeVacatedSlot(session.id, projectId: projectId)
        if agentId != nil { markAttached(session) }
        if let prompt, !prompt.isEmpty { initialPrompts[session.id!] = prompt }
        reload()
        selectedSessionId = session.id
        if let folder = workdir(of: session), work[folder] == nil { Task { await refreshWork(folder) } }
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
        if let latest = orderedSessions.last(where: { $0.projectId == projectId && $0.sshHost == nil }) {
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
        takeVacatedSlot(fresh, projectId: old.projectId) // the fresh claude sits where the old one did
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
        if tabOrder.contains(id), let projectId = sessions.first(where: { $0.id == id })?.projectId { vacatedSlots[id] = projectId }
        terminals.close(id)
        runningSessionIds.remove(id)
        exitedSessionIds.remove(id)
        guidedSessionIds.remove(id)
        darkSessionIds.remove(id)
        lastTurnEvents[id] = nil
        initialPrompts[id] = nil
        holds[id] = nil
        if let session = sessions.first(where: { $0.id == id }), session.agentId != nil { markAttached(session, false) }
        _ = try? db.write { try Session.deleteOne($0, id: id) }
        if let split = splitBeforeShells, !sessions.contains(where: { $0.id != id && $0.sshHost != nil }) {
            splitBeforeShells = nil
            editShell { $0.split = split }
        }
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
        // Shells: a local terminal just starts, a server shell waits for Connect (connectShell).
        guard existing.sshHost == nil else { if existing.isLocalTerminal { connectShell(sessionId) }; return }
        if existing.portBase == nil { assignPortBase(sessionId) } // sessions from before module 5
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        terminals.start(session, projectPath: project.path, initialPrompt: initialPrompts.removeValue(forKey: sessionId),
                        login: login,
                        remoteControlName: remoteControlForNewSessions ? [project.name, session.branch].compactMap { $0 }.joined(separator: " · ") : nil,
                        guided: guidedMode, asks: databaseAsks(for: project.id), attach: attachId(for: session))
        runningSessionIds.insert(sessionId)
        if guidedMode { guidedSessionIds.insert(sessionId) } else { guidedSessionIds.remove(sessionId) }
        if TerminalRegistry.isDark { darkSessionIds.insert(sessionId) } else { darkSessionIds.remove(sessionId) }
    }

    func restartSession(_ id: Int64) {
        holds[id] = nil
        terminals.close(id)
        exitedSessionIds.remove(id)
        if sessions.first(where: { $0.id == id })?.sshHost != nil { connectShell(id) } else { startTerminalIfNeeded(id) }
    }

    /// A shell on the server; it connects right away. `shellsBeside`: right after the selected session of the same
    /// project — tabs follow createdAt, so it's dated just after that one — and the two side by side.
    func openShell(on server: Server) throws {
        guard ServerLogs.isValidHost(server.host) else { throw ServerError.badHost(server.host) }
        try openShellSession(projectId: server.projectId, host: server.host, name: server.label.isEmpty ? nil : server.label)
    }

    /// + → Terminal: the user's own shell in the project folder, like VS Code's terminal — placed like a server shell.
    func openTerminal(projectId: Int64? = nil) throws {
        guard let projectId = projectId ?? selectedSession?.projectId ?? projects.first?.id else { return }
        try openShellSession(projectId: projectId, host: Session.localTerminal, name: nil)
    }

    private func openShellSession(projectId: Int64, host: String, name: String?) throws {
        let partner = shellsBeside ? selectedSession.flatMap { $0.projectId == projectId ? $0 : nil } : nil
        // The database keeps milliseconds: halfway to the session after the partner (another shell beside it, too),
        // at most 10 ms on; a tie with the partner sorts after it by id. +0.1 ms so rounding never drops a millisecond.
        let createdAt = partner.map { partner in
            let next = sessions.first { $0.projectId == partner.projectId && $0.createdAt > partner.createdAt }
            let gap = next.map { Int(($0.createdAt.timeIntervalSince(partner.createdAt) * 1000).rounded()) } ?? 20
            return partner.createdAt.addingTimeInterval(Double(min(10, gap / 2)) / 1000 + 0.0001)
        } ?? .now
        var session = Session(projectId: projectId, claudeSessionId: UUID().uuidString.lowercased(),
                              status: .idle, createdAt: createdAt, lastActiveAt: .now, name: name, sshHost: host)
        try db.write { try session.insert($0) }
        reload()
        if let partner {
            if shell.split < 2 {
                splitBeforeShells = splitBeforeShells ?? shell.split
                editShell { $0.split = 2 }
            }
            paneAnchor = partner.id
        }
        selectedSessionId = session.id
        if let id = session.id { connectShell(id) }
    }

    /// The split before a shell opened beside a session widened it; the last shell closing puts it back.
    private var splitBeforeShells: Int?

    /// `ssh <host>` in the session's terminal. Only on the user's click: after meepo restarts a shell waits for Connect,
    /// so no server gets logins nobody asked for (a local terminal starts on its own). Like claude, waits for the login
    /// environment (never resolved in tests).
    func connectShell(_ id: Int64) {
        guard isLoginResolved, terminals.view(for: id) == nil, let session = sessions.first(where: { $0.id == id }),
              let host = session.sshHost, let project = project(for: session) else { return }
        let (executable, arguments): (String, [String])
        if session.isLocalTerminal {
            (executable, arguments) = (ClaudeLauncher.defaultShell, ["-l"])
        } else {
            guard let ssh = ServerLogs.shellArguments(host: host) else { return }
            (executable, arguments) = (ServerLogs.ssh, ssh)
        }
        let environment = loginEnvironment?.environment ?? ClaudeLauncher.scrubbed(ProcessInfo.processInfo.environment)
        terminals.startShell(session, executable: executable, arguments: arguments, environment: environment, directory: project.path)
        exitedSessionIds.remove(id)
        runningSessionIds.insert(id)
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
        } else if elsewhere.contains(where: \.needsYou) {
            isHomeShown = true // only an agent outside meepo waits: Home shows it
        }
    }

    // MARK: Sessions outside meepo

    /// Background agents and claude in other windows (Terminal, VS Code…), meepo's own left out; interactive
    /// ones that ended in this run stay a day, for Continue here.
    private(set) var elsewhere: [ClaudeAgents.Agent] = []
    /// Every running background agent, meepo's own too: an agent opened here re-attaches only while it runs.
    private var backgroundAgentIds: Set<String> = []
    /// A `claude agents` list came back in this run: until then a tab opened on an agent attaches rather than
    /// resuming a conversation the agent may still be running.
    private var isAgentListKnown = false
    /// The latest refresh: a slower, older one that comes back after it is dropped.
    @ObservationIgnored private var elsewhereRefreshes = 0
    /// The agent whose recent output is shown (Output).
    var outputAgent: ClaudeAgents.Agent?

    /// Off the main actor; nothing while claude isn't found (or in Demo, which has its own).
    func refreshElsewhere() async {
        guard !isDemo, let login = loginEnvironment else { return }
        await refreshElsewhere { ClaudeAgents.list(login: login) }
    }

    func refreshElsewhere(_ list: @escaping @Sendable () -> [ClaudeAgents.Agent]?) async {
        elsewhereRefreshes += 1
        let refresh = elsewhereRefreshes
        guard let agents = await Task.detached(operation: list).value, refresh == elsewhereRefreshes else { return }
        applyAgents(agents)
    }

    func applyAgents(_ agents: [ClaudeAgents.Agent], now: Date = .now) {
        backgroundAgentIds = Set(agents.filter(\.isBackground).map(\.id))
        followClearedAgents(agents)
        if !isAgentListKnown { reconcileAttached() }
        isAgentListKnown = true
        let own = Set(sessions.map(\.claudeSessionId)), ownAgents = Set(sessions.compactMap(\.agentId))
        elsewhere = ClaudeAgents.merge(ClaudeAgents.others(agents, ownSessionIds: own), into: elsewhere, now: now)
            .filter { !own.contains($0.sessionId ?? "") && !ownAgents.contains($0.id) }
    }

    /// `/clear` in an agent open here gives it a new session id; its hooks then carry that one, and the bridge
    /// finds the tab only by it (the SessionStart saying so can't reach meepo), so the list tells.
    private func followClearedAgents(_ agents: [ClaudeAgents.Agent]) {
        for agent in agents where agent.isBackground {
            guard let sessionId = agent.sessionId,
                  var session = sessions.first(where: { $0.agentId == agent.id && $0.claudeSessionId != sessionId })
            else { continue }
            markAttached(session, false)
            session.claudeSessionId = sessionId
            _ = try? db.write { try session.update($0) }
            markAttached(session)
            reload()
        }
    }

    /// Once per run: a marker is kept only for a tab whose agent still runs; the rest (tabs closed while meepo
    /// wasn't running, agents that ended) go, and the folder with them when none is left.
    private func reconcileAttached() {
        let dir = bridge.attachedURL, fm = FileManager.default
        let attached = sessions.filter { $0.agentId.map(backgroundAgentIds.contains) == true }
        let keep = Dictionary(attached.compactMap { s in s.id.map { (s.claudeSessionId, String($0)) } }) { a, _ in a }
        for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where keep[file.lastPathComponent] != (try? String(contentsOf: file, encoding: .utf8)) {
            try? fm.removeItem(at: file)
        }
        for session in attached { markAttached(session) }
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
    }

    /// The agent to attach to when the session's terminal starts; nil = the usual claude (--resume). Before any
    /// list came back it attaches: a second claude resuming a conversation its agent still runs would fork it.
    func attachId(for session: Session) -> String? {
        session.agentId.flatMap { !isAgentListKnown || backgroundAgentIds.contains($0) ? $0 : nil }
    }

    /// The agent's folder isn't a meepo project yet: opening it adds one.
    func isNewProject(_ agent: ClaudeAgents.Agent) -> Bool {
        agent.cwd.map { projectId(containing: $0) == nil } ?? false
    }

    private func projectId(containing folder: String) -> Int64? {
        projects.filter { folder == $0.path || folder.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }?.id
    }

    /// Background agent → a meepo tab attached to it (stages, What changed, events, notifications: its hook
    /// events find the tab by its claude session id). Closing the tab doesn't stop it.
    func openHere(_ agent: ClaudeAgents.Agent) throws {
        guard agent.isBackground, let sessionId = agent.sessionId, let cwd = agent.cwd else { return }
        try adopt(agent, sessionId: sessionId, cwd: cwd, agentId: agent.id)
        if isDemo, let id = selectedSessionId { // Demo runs nothing: the tab shows the agent's page
            terminals.showText(Demo.agentOutput.replacingOccurrences(of: "\n", with: "\r\n"), for: id)
            runningSessionIds.insert(id)
        }
    }

    /// An interactive session its window has ended → its conversation continues in a meepo tab (claude --resume).
    func continueHere(_ agent: ClaudeAgents.Agent) throws {
        guard agent.canContinueHere, let sessionId = agent.sessionId, let cwd = agent.cwd else { return }
        try adopt(agent, sessionId: sessionId, cwd: cwd, agentId: nil)
    }

    private func adopt(_ agent: ClaudeAgents.Agent, sessionId: String, cwd: String, agentId: String?) throws {
        if projectId(containing: cwd) == nil { try addProject(at: URL(filePath: cwd)) }
        guard let projectId = projectId(containing: cwd) else { return }
        try createSession(projectId: projectId, model: nil, prompt: nil, resuming: sessionId, name: agent.name,
                          agentId: agentId, folder: cwd)
        elsewhere.removeAll { $0.sessionId == sessionId }
    }

    /// `claude stop <id>`: the agent stops, its conversation is kept.
    func stopAgent(_ agent: ClaudeAgents.Agent) async {
        guard agent.isBackground else { return }
        if isDemo { elsewhere.removeAll { $0.id == agent.id }; return }
        guard let login = loginEnvironment else { return }
        let (ok, output) = await Task.detached { ClaudeAgents.run(["stop", agent.id], login: login) }.value
        if !ok { bridgeError = "claude stop \(agent.id): " + ClaudeAgents.plainText(output).trimmingCharacters(in: .whitespacesAndNewlines) }
        await refreshElsewhere()
    }

    /// `claude logs <id>` as plain text.
    func agentOutput(_ agent: ClaudeAgents.Agent) async -> String {
        if isDemo { return Demo.agentOutput }
        guard let login = loginEnvironment else { return "claude isn't found in the login shell" }
        let output = await Task.detached { ClaudeAgents.run(["logs", agent.id], login: login).output }.value
        return ClaudeAgents.plainText(output)
    }

    /// The marker that lets the hook bridge find this tab for the agent's events (see BridgeInstaller.attachedURL).
    private func markAttached(_ session: Session, _ on: Bool = true) {
        guard let id = session.id else { return }
        let dir = bridge.attachedURL, fm = FileManager.default
        if on {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(String(id).utf8).write(to: dir.appending(path: session.claudeSessionId), options: .atomic)
            return
        }
        for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where (try? String(contentsOf: file, encoding: .utf8)) == String(id) {
            try? fm.removeItem(at: file)
        }
        // No folder when nothing is attached: every other session's hooks then exit at once.
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
    }
}

// MARK: Demo mode

extension AppStore {
    /// Fills an empty store with Demo's made-up projects: real git folders in a temp directory (so Source
    /// Control and Explorer work), sessions in every state, an hour of events, live numbers, a summary and
    /// suggestions. Nothing of the user's is read or written.
    func loadDemo() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "Meepo Demo")
        // ~30 git runs and the files: off the main thread. The first push's commit per project, for its summary.
        let pushes = await Task.detached { () -> [String: String] in
            try? FileManager.default.removeItem(at: root)
            /// git as if it ran `minutesAgo`: commits and pushes (the upstream's reflog) get that time. None of the
            /// user's git config: signing would ask for a key, their hooks would run on made-up commits.
            func git(_ args: [String], in folder: URL, minutesAgo: Double = 0) {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/git")
                process.arguments = ["-c", "user.name=Meepo", "-c", "user.email=demo@meepo.app", "-c", "commit.gpgsign=false",
                                     "-c", "core.hooksPath=/dev/null", "-C", folder.path] + args
                let stamp = "@\(Int(Date.now.timeIntervalSince1970 - minutesAgo * 60)) +0000"
                process.environment = ProcessInfo.processInfo.environment.merging([
                    "GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                ]) { $1 }
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitForExit()
            }
            func write(_ text: String, to url: URL) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            var pushes: [String: String] = [:]
            for project in Demo.projects {
                let folder = root.appending(path: project.name)
                for (file, text) in project.files { write(text, to: folder.appending(path: file)) }
                // "Sent to GitHub": origin reads as GitHub, pushes land in a folder next to it.
                let remotes = root.appending(path: "remotes")
                git(["init", "-q", "--bare", "-b", "main", remotes.appending(path: "\(project.name).git").path], in: root)
                git(["init", "-q", "-b", "main"], in: folder)
                git(["remote", "add", "origin", "git@github.com:acme/\(project.name).git"], in: folder)
                git(["config", "url.\(remotes.path)/.pushInsteadOf", "git@github.com:acme/"], in: folder)
                git(["add", "."], in: folder, minutesAgo: 60 * 24 * 10)
                git(["commit", "-q", "-m", "Start"], in: folder, minutesAgo: 60 * 24 * 10)
                git(["push", "-q", "-u", "origin", "main"], in: folder, minutesAgo: 60 * 24 * 10)
                for commit in project.history {
                    write(commit.text, to: folder.appending(path: commit.file))
                    git(["add", "."], in: folder, minutesAgo: commit.minutesAgo)
                    git(["commit", "-q", "-m", commit.message], in: folder, minutesAgo: commit.minutesAgo)
                    if let pushed = commit.pushed {
                        git(["push", "-q"], in: folder, minutesAgo: pushed)
                        if pushes[project.name] == nil { pushes[project.name] = GitService.headCommit(in: folder.path) }
                    }
                }
                if let change = project.change { write(change.text, to: folder.appending(path: change.file)) }
            }
            return pushes
        }.value
        for project in Demo.projects { try? addProject(at: root.appending(path: project.name)) }
        isBridgeInstalled = true
        isLoginResolved = true
        isDemo = true
        isVoiceOn = false
        claudeAuthMethod = "claude.ai"
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
        elsewhere = Demo.agents { name in projects.first { $0.name == name }?.path }
        // Earlier requests behind the pushes, and Explain for users on storefront's Kaspi push, for What changed and Today.
        let ids = sessions.compactMap(\.id)
        var events: [HookEvent] = []
        for run in Demo.earlier where ids.indices.contains(run.session) {
            let (id, start) = (ids[run.session], Date.now.addingTimeInterval(-run.minutesAgo * 60))
            events.append(HookEvent(sessionId: id, name: "UserPromptSubmit", summary: run.request, isFailure: false, createdAt: start))
            if let file = run.file, let project = projects.first(where: { $0.id == sessions[run.session].projectId }) {
                events.append(HookEvent(sessionId: id, name: "PostToolUse", summary: "Write: \(project.path)/\(file)",
                                        isFailure: false, createdAt: start + run.minutes * 20))
            }
            if let helper = run.helper {
                let note = "<task-notification>\n<summary>Agent \"\(helper)\" finished</summary>\n</task-notification>"
                events.append(HookEvent(sessionId: id, name: "UserPromptSubmit", summary: note, isFailure: false,
                                        createdAt: start + run.minutes * 40))
            }
            events.append(HookEvent(sessionId: id, name: "Stop", summary: run.reply, isFailure: false, createdAt: start + run.minutes * 60))
        }
        let explained = projects.first { $0.name == "storefront" }.flatMap { project in pushes["storefront"].map { (project.path, "sent:" + $0) } }
        _ = try? await db.write { [events] db in
            for var event in events { try event.insert(db) }
            if let (folder, unit) = explained {
                try db.execute(sql: "INSERT INTO workSummary (folder, unit, json, createdAt) VALUES (?, ?, ?, ?)",
                               arguments: [folder, unit, Demo.summary, Date.now])
            }
        }
        // storefront's Kaspi work waits for a deploy: the card, Today and What changed say so.
        if let storefront = projects.first(where: { $0.name == "storefront" }), let id = storefront.id,
           let head = GitService.headCommit(in: storefront.path) {
            pipelines[id] = Pipeline(branch: "main", sha: head, steps: [
                Pipeline.Step(name: "CI", state: .passed, started: .now - 7000, finished: .now - 6800),
                Pipeline.Step(name: "Build & Push", state: .passed, started: .now - 6790, finished: .now - 6600),
                Pipeline.Step(name: "Deploy", state: .manual, trigger: "deploy.yml"),
            ], title: "fix(orders): totals include delivery")
        }
        reloadTitles()
        reloadLastLines()
        await refreshWork()
        suggestions = [Noticing.Suggestion(kind: .chain(["simplify", "ship", "sync"]), count: 25),
                       Noticing.Suggestion(kind: .skill(phrase: "check the staging deploy and tell me what broke"), count: 7)]
        defaults.set("2.1.281", forKey: "claudeCodeVersionSeen")
        let changelog = (try? String(contentsOf: ClaudeChangelog.cacheFile, encoding: .utf8)) ?? ""
        noteClaudeVersion("2.1.282", changelog: changelog)
        selectedSessionId = sessions.first?.id
    }
}
