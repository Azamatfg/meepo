import Foundation
import GRDB

/// Where an open task stands. What agents find while they work lands in the inbox, not in the list.
enum TaskStatus: String, Codable, CaseIterable, DatabaseValueConvertible {
    /// Written by an agent's `sqlite3` (the column's default), not sorted yet.
    case inbox
    /// The list being worked on.
    case active
    /// Not now.
    case later
    /// Waits for someone else.
    case waiting
}

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
    /// Typed in Meepo → active. A row an agent inserts without it gets the column's default, inbox.
    var status = TaskStatus.active
    var createdAt: Date = .now
    var doneAt: Date?
    /// The session the task was last launched in.
    var sessionId: Int64?
    /// Its own workspace; nil = its project's (AppStore.workspace(of:)).
    var workspace: String? = nil

    /// Screenshots taken for tasks; they belong to the task and go when it is deleted.
    static var attachmentsDir: URL { MeepoHome.url.appending(path: "attachments") }

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

    /// In the list being worked on: open and active.
    var isActive: Bool { !isDone && status == .active }

    /// The note's last line: what a session closing the task wrote it ended with (a PR, a deploy).
    var outcome: String? {
        note.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
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
