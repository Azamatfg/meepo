import Foundation
import GRDB

struct Project: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var path: String
    var remote: String?
    var color: String?
    /// Important (production): every server and database command its sessions run asks first.
    var isImportant: Bool = false

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
