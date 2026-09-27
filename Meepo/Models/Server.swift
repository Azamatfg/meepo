import Foundation
import GRDB

/// A server a project runs on (SPEC module 10): an ssh host — an alias from ~/.ssh/config or user@host — and where
/// its logs are. meepo stores no keys: the system ssh and ssh-agent log in.
struct Server: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: Int64
    var host: String
    /// "prod", "stage"; empty = the host is the name.
    var label: String = ""
    var sources: [LogSource] = []

    var title: String { label.isEmpty ? host : "\(label) · \(host)" }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One place a server's logs come from — only ever run through its read-only template.
struct LogSource: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case journal, docker, file

        var title: String {
            switch self {
            case .journal: "Service (journalctl)"
            case .docker: "Container (docker logs)"
            case .file: "File (tail)"
            }
        }
    }

    var kind: Kind
    /// A systemd unit, a container name or an absolute file path.
    var name: String

    var id: String { "\(kind.rawValue):\(name)" }
}
