import Foundation
import GRDB
import Observation
import SwiftTerm

enum AddProjectError: LocalizedError, Equatable {
    case alreadyAdded(String)

    var errorDescription: String? {
        switch self {
        case .alreadyAdded(let name): "Проект «\(name)» уже добавлен"
        }
    }
}

@MainActor
@Observable
final class AppStore {
    private let db: DatabaseQueue
    private let terminals = TerminalRegistry()
    /// First prompt of a freshly created session; used once, never stored.
    private var initialPrompts: [Int64: String] = [:]
    private var loginEnvironment: ClaudeLauncher.LoginEnvironment?

    private(set) var projects: [Project] = []
    private(set) var sessions: [Session] = []
    private(set) var runningSessionIds: Set<Int64> = []
    private(set) var exitedSessionIds: Set<Int64> = []
    var selectedSessionId: Int64?
    /// Non-nil while the "new session" sheet is shown; the project preselected in it.
    var newSessionProjectId: Int64?

    init(db: DatabaseQueue) {
        self.db = db
        reload()
        selectedSessionId = orderedSessions.first?.id
        terminals.onExit = { [weak self] id in
            self?.runningSessionIds.remove(id)
            self?.exitedSessionIds.insert(id)
        }
    }

    /// Resolves the login shell environment once, then brings every saved session back
    /// in the background so switching to it is instant.
    func restoreSessions() async {
        loginEnvironment = await Task.detached { ClaudeLauncher.resolveLoginEnvironment() }.value
        for session in orderedSessions {
            if let id = session.id { startTerminalIfNeeded(id) }
        }
    }

    func reload() {
        projects = (try? db.read { try Project.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll($0) }) ?? []
        sessions = (try? db.read { try Session.order(Column("createdAt")).fetchAll($0) }) ?? []
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
    /// Before `restoreSessions` resolves the login environment, falls back to a shell launch.
    func startTerminalIfNeeded(_ sessionId: Int64) {
        guard terminals.view(for: sessionId) == nil,
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
