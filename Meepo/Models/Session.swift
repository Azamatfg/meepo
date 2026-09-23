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
    var status: SessionStatus
    var createdAt: Date
    var lastActiveAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
