import Foundation
import GRDB

/// A past commit made into a Replay task: the instruction the agent gets, and the check that grades it.
struct ReplayTask: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "replayTask"

    var id: Int64?
    var projectId: Int64
    var sha: String
    var subject: String
    var instruction: String
    var checkCommand: String
    /// The commit's test files, put in only after the agent is done.
    var tests: [String]
    /// nil until validated: doing nothing must fail the check, the commit itself must pass it every time.
    var isValid: Bool?
    var createdAt: Date = .now

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One attempt at a task on one setup.
struct ReplayRun: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "replayRun"

    var id: Int64?
    var taskId: Int64
    var model: String
    var effort: String
    /// nil: the run itself broke (claude didn't start, the snapshot failed) — not the agent's failure.
    var passed: Bool?
    var costUsd: Double = 0
    var seconds: Double = 0
    var turns: Int = 0
    var error: String?
    var createdAt: Date = .now

    var setup: Replay.Setup { Replay.Setup(model: model, effort: effort) }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
