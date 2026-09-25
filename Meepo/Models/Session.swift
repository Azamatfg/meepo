import Foundation
import GRDB

enum SessionStatus: String, Codable, DatabaseValueConvertible {
    case thinking
    case waitingInput = "waiting_input"
    case waitingPermission = "waiting_permission"
    case idle
    case needsSync = "needs_sync"
    case error
}

struct Session: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: Int64
    /// UUID passed to `claude --session-id`; used for `claude --resume` after restart.
    var claudeSessionId: String
    var model: String?
    /// `claude --effort` level; nil = Claude Code's default.
    var effort: String?
    var branch: String?
    /// Workflow stage (a stage name from Settings), from the last slash command run in the session.
    var stage: String?
    /// Set for a parallel feature: `claude -w <name>` works in `<repo>/.claude/worktrees/<name>`.
    var worktreeName: String?
    /// Commit the worktree branched from; "merged" only counts once the branch moved past it.
    var worktreeBase: String?
    /// First of the session's 10 ports (PORT, MEEPO_PORT_BASE).
    var portBase: Int?
    var status: SessionStatus
    var createdAt: Date
    var lastActiveAt: Date
    /// The user's name for it (`claude --name`), so two sessions of one project can be told apart.
    var name: String? = nil

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
