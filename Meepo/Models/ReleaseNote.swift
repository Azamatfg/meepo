import Foundation
import GRDB

/// A release note draft (SPEC module 12): written on NEW, edited and copied out by the user.
struct ReleaseNote: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "releaseNote"

    var id: Int64?
    var projectId: Int64
    /// HEAD the note covers up to; the next note starts after it.
    var sha: String
    var text: String
    var createdAt: Date = .now

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
