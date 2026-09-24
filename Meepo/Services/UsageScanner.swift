import Foundation
import GRDB
import os

private let log = Logger(subsystem: "com.azamatfg.meepo", category: "usage")

/// Incrementally reads `~/.claude/projects/**/*.jsonl` (sessions and their subagents) into `usageRecord`.
/// Per file it remembers the byte offset of the last complete line, so restarts and `--resume`
/// (which appends to the same file) never count a response twice.
enum UsageScanner {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")

    /// Blocking; call off the main thread. Returns how many new responses were recorded.
    @discardableResult
    static func scan(root: URL = defaultRoot, into db: DatabaseQueue) throws -> Int {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        let offsets = try db.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT path, offset FROM scanState")
                .map { ($0["path"] as String, $0["offset"] as Int) })
        }
        var added = 0
        for case let url as URL in files where url.pathExtension == "jsonl" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var offset = offsets[url.path] ?? 0
            if offset > size { offset = 0 } // file was rewritten; message ids keep this from double counting
            guard size > offset else { continue }
            added += try scanFile(url, from: offset, into: db)
        }
        return added
    }

    private static func scanFile(_ url: URL, from offset: Int, into db: DatabaseQueue) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = handle.readDataToEndOfFile()
        let parsed = parse(data)
        if parsed.badLines > 0 { log.notice("\(url.lastPathComponent, privacy: .public): skipped \(parsed.badLines) unreadable lines") }
        guard parsed.consumed > 0 else { return 0 }
        let blocks = parseBlocks(data.prefix(parsed.consumed))
        return try db.write { db in
            let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usageRecord") ?? 0
            for record in parsed.records { try upsert(record, db) }
            for block in blocks { try insert(block, db) }
            let added = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usageRecord") ?? 0) - before
            try db.execute(sql: "INSERT OR REPLACE INTO scanState (path, offset) VALUES (?, ?)",
                           arguments: [url.path, offset + parsed.consumed])
            return added
        }
    }

    /// A response is written in several lines as it streams; later lines carry the final (larger) usage,
    /// possibly in a later scan. Counters only grow, so keeping the max per field is order-independent.
    private static func upsert(_ r: UsageRecord, _ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO usageRecord (messageId, claudeSessionId, cwd, model, createdAt, isSidechain,
                                     inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(messageId) DO UPDATE SET
                inputTokens = MAX(inputTokens, excluded.inputTokens),
                outputTokens = MAX(outputTokens, excluded.outputTokens),
                cacheCreationTokens = MAX(cacheCreationTokens, excluded.cacheCreationTokens),
                cacheReadTokens = MAX(cacheReadTokens, excluded.cacheReadTokens)
            """, arguments: [r.messageId, r.claudeSessionId, r.cwd, r.model, r.createdAt, r.isSidechain,
                             r.inputTokens, r.outputTokens, r.cacheCreationTokens, r.cacheReadTokens])
    }

    /// A tool call the user's own PreToolUse hook refused (exit 2). Claude Code sends no hook event for it
    /// (checked live, 2.1.281: PreToolUse, then nothing), so the transcript's tool_result is the only trace.
    struct Block: Equatable {
        let claudeSessionId: String
        let createdAt: Date
        let summary: String
    }

    /// Lines like `"content":"PreToolUse:Bash hook error: [/path/pre-bash-safety.sh]: rm is not allowed"`.
    static func parseBlocks(_ data: Data) -> [Block] {
        let marker = Data("PreToolUse:".utf8)
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line -> Block? in
            guard line.range(of: marker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let sessionId = object["sessionId"] as? String,
                  let createdAt = (object["timestamp"] as? String).flatMap(date),
                  let content = ((object["message"] as? [String: Any])?["content"] as? [[String: Any]])?
                    .first(where: { $0["type"] as? String == "tool_result" && $0["is_error"] as? Bool == true })?["content"],
                  let text = (content as? String) ?? (content as? [[String: Any]])?.compactMap({ $0["text"] as? String }).first,
                  let match = text.firstMatch(of: /^PreToolUse:(\S+) hook error: \[([^\]]*)\]: (.*)/.dotMatchesNewlines())
            else { return nil }
            let hook = URL(filePath: String(match.2)).lastPathComponent
            let reason = match.3.split(separator: "\n").first.map(String.init) ?? ""
            return Block(claudeSessionId: sessionId, createdAt: createdAt, summary: "\(match.1) blocked by \(hook): \(reason)")
        }
    }

    /// Into the feed of the Meepo session it belongs to; transcripts of other sessions are skipped.
    private static func insert(_ block: Block, _ db: Database) throws {
        guard let sessionId = try Int64.fetchOne(db, sql: "SELECT id FROM session WHERE claudeSessionId = ?",
                                                 arguments: [block.claudeSessionId]),
              try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hookEvent WHERE sessionId = ? AND name = 'HookBlocked' AND createdAt = ?",
                               arguments: [sessionId, block.createdAt]) == 0 else { return }
        var event = HookEvent(sessionId: sessionId, name: "HookBlocked", summary: block.summary, isFailure: true, createdAt: block.createdAt)
        try event.insert(db)
    }

    /// Parses complete lines only; a trailing line without "\n" is still being written and waits for the next scan.
    /// Unknown line types and fields are ignored, broken lines are counted and skipped.
    static func parse(_ data: Data) -> (records: [UsageRecord], consumed: Int, badLines: Int) {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0, 0) }
        let complete = data[data.startIndex...lastNewline]
        var records: [UsageRecord] = []
        var bad = 0
        let usageKey = Data(#""usage""#.utf8)
        for line in complete.split(separator: UInt8(ascii: "\n")) where line.range(of: usageKey) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                bad += 1
                continue
            }
            if let record = record(from: object) { records.append(record) }
        }
        return (records, complete.count, bad)
    }

    /// Claude Code writes "2026-09-23T16:31:03.640Z"; accept it without fractions too.
    private static func date(_ string: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }

    static func record(from line: [String: Any]) -> UsageRecord? {
        guard line["type"] as? String == "assistant",
              let message = line["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let id = (message["id"] ?? line["requestId"] ?? line["uuid"]) as? String,
              let sessionId = line["sessionId"] as? String,
              let timestamp = (line["timestamp"] as? String).flatMap(date) else { return nil }
        func tokens(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return UsageRecord(
            messageId: id,
            claudeSessionId: sessionId,
            cwd: line["cwd"] as? String ?? "",
            model: message["model"] as? String ?? "unknown",
            createdAt: timestamp,
            isSidechain: line["isSidechain"] as? Bool ?? false,
            inputTokens: tokens("input_tokens"),
            outputTokens: tokens("output_tokens"),
            cacheCreationTokens: tokens("cache_creation_input_tokens"),
            cacheReadTokens: tokens("cache_read_input_tokens")
        )
    }
}
