import Foundation
import GRDB

/// A to-do for a project (SPEC module 7): typed or pasted in Meepo, launched as a session's first prompt.
/// Open tasks carry over to the next morning.
struct TaskItem: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "task"

    var id: Int64?
    /// nil = not sorted into a project yet.
    var projectId: Int64?
    var text: String
    var note: String = ""
    /// File paths (incl. screenshots) and links that go with the task into the session.
    var attachments: [String] = []
    var isDone = false
    var createdAt: Date = .now
    var doneAt: Date?
    /// The session the task was last launched in.
    var sessionId: Int64?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The session's first message: the task, its note and attachments (Claude reads files by path).
    var prompt: String {
        var parts = [text]
        if !note.isEmpty { parts.append("Notes:\n\(note)") }
        if !attachments.isEmpty { parts.append("Attachments:\n" + attachments.map { "- \($0)" }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }
}

/// A TODO/FIXME/HACK/XXX line Claude wrote into code (from PostToolUse), for the end-of-day summary.
struct AgentTodo: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var projectId: Int64
    var file: String
    var line: String
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
