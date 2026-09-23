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
    var branch: String?
    var status: SessionStatus
    var createdAt: Date
    var lastActiveAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
