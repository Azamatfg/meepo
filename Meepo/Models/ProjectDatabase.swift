import Foundation
import GRDB

/// A project's Postgres, as Claude and meepo use it: the read-only role's address (Postgres.role). The owner's
/// address is used once, to create that role, and never kept.
struct ProjectDatabase: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "projectDatabase"

    var id: Int64?
    var projectId: Int64
    /// The database name, or what the user calls it.
    var label: String
    /// Where meepo and Claude connect: through the tunnel's local port when the database is on a server.
    var url: String
    /// The server the database runs on (Server.id); nil = reachable from this Mac as it is.
    var serverId: Int64? = nil
    /// Where the database listens as that server sees it, and the local port meepo forwards to it.
    var remoteHost: String? = nil
    var remotePort: Int? = nil
    var localPort: Int? = nil
    /// Its server's name in the project's .mcp.json ("postgres-main"); nil for one saved before meepo tracked it.
    var mcpName: String? = nil
    /// Every query Claude makes asks first (the SQL shown, Allow or Deny) — on for production.
    var asksEachQuery: Bool = false

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
