import Foundation
import GRDB

/// Token usage of one model response, read from Claude Code's session JSONL.
/// Keyed by the API message id: Claude Code writes one response as several lines (text, tool use…)
/// as it streams; each repeats the usage so far, the last one is final. See `UsageScanner.upsert`.
struct UsageRecord: Codable, Hashable, FetchableRecord, PersistableRecord {
    var messageId: String
    var claudeSessionId: String
    var cwd: String
    var model: String
    var createdAt: Date
    /// Subagent responses: their tokens count, but they aren't in the main conversation's context.
    var isSidechain: Bool
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int

    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
    /// What the model had in its window when it answered.
    var contextTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens }
}
