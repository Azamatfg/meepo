import Foundation
import GRDB

struct Project: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var path: String
    var remote: String?
    var color: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
