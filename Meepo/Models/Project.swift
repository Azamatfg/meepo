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
    /// Meepo's method, VERIFY: the command that proves a change works (build, tests). A turn that changed files
    /// can't end until it passes — the mod runs it at Stop. nil = no check.
    var checkCommand: String?
    /// Where the work is (personal, a job, a client): the sidebar shows one workspace at a time, or all.
    var workspace: String? = nil
    /// Files linked projects depend on (globs relative to the project: "api/openapi.yaml", "proto/**").
    var contractPaths: [String]? = nil
    /// Projects that work together with this one (a backend and its app); kept the same on both sides.
    var linkedProjectIds: [Int64]? = nil

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
