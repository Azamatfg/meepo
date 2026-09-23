import Foundation
import GRDB

/// One Claude Code hook event of a Meepo session, as shown in the event feed.
struct HookEvent: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var sessionId: Int64
    var name: String
    var summary: String?
    var isFailure: Bool
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
