import Foundation

/// A session's context window by part, as Meepo's mod measures it after each turn (`$.session.usage({ breakdown:
/// "summary" })`, estimated locally — no API call): what fills it, which CLAUDE.md and memory files, skills, MCP.
struct ContextUsage: Decodable, Equatable {
    struct Part: Decodable, Equatable { var name: String; var tokens: Int; var kind: String }
    struct MemoryFile: Decodable, Equatable { var path: String; var type: String; var tokens: Int }
    struct Skill: Decodable, Equatable { var name: String; var tokens: Int }
    struct Server: Decodable, Equatable { var server: String; var tokens: Int }

    var percent: Int?
    var tokens: Int?
    var window: Int
    /// Where auto-compaction starts, in tokens; nil = off.
    var autoCompactAt: Int?
    var categories: [Part]
    var memoryFiles: [MemoryFile]
    var skills: [Skill]
    var mcp: [Server]

    /// What occupies the window (not free space, the compaction reserve or on-demand schemas), heaviest first.
    var used: [Part] { categories.filter { $0.kind == "used" && $0.tokens > 0 }.sorted { $0.tokens > $1.tokens } }

    init?(json: Data) {
        guard let event = try? JSONDecoder().decode(Kind.self, from: json), event.hook_event_name == "ContextUsage",
              var usage = try? JSONDecoder().decode(Self.self, from: json) else { return nil }
        usage.memoryFiles.sort { $0.tokens > $1.tokens }
        usage.skills.sort { $0.tokens > $1.tokens }
        usage.mcp.sort { $0.tokens > $1.tokens }
        self = usage
    }

    private struct Kind: Decodable { var hook_event_name: String }
}

/// A CLAUDE.md or rules file Claude Code loaded into the session, and why (InstructionsLoaded).
struct LoadedInstruction: Decodable, Equatable {
    var path: String
    var type: String
    /// session_start, nested_traversal, path_glob_match, include, compact.
    var reason: String

    init?(json: Data) {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: json), raw.hook_event_name == "InstructionsLoaded" else { return nil }
        (path, type, reason) = (raw.file_path, raw.memory_type, raw.load_reason)
    }

    private struct Raw: Decodable { var hook_event_name, file_path, memory_type, load_reason: String }
}

extension AppStore {
    /// The mod's measurement or an InstructionsLoaded; true when it was one (it isn't a hook event for the feed).
    func applyContextReport(_ json: Data, sessionId: Int64) -> Bool {
        if let usage = ContextUsage(json: json) {
            if contextUsage[sessionId] != usage { contextUsage[sessionId] = usage }
            return true
        }
        if let loaded = LoadedInstruction(json: json) {
            var list = (loadedInstructions[sessionId] ?? []).filter { $0.path != loaded.path }
            list.append(loaded)
            loadedInstructions[sessionId] = list
            return true
        }
        return false
    }
}
