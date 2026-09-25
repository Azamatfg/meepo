import Foundation

/// What changed in Claude Code between two versions, from the changelog Claude Code itself keeps up to date
/// in ~/.claude/cache/changelog.md — no network, no tokens.
enum ClaudeChangelog {
    static let cacheFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/cache/changelog.md")

    struct Release: Equatable {
        let version: String
        var items: [String]
    }

    /// Releases newer than `after` up to and including `upTo`, newest first.
    static func releases(in text: String, after: String, upTo: String) -> [Release] {
        guard let old = Updater.Version(after), let new = Updater.Version(upTo) else { return [] }
        var result: [Release] = []
        var current: Release?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if let current { result.append(current) }
                let tag = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                current = Updater.Version(tag).flatMap { $0 > old && $0 <= new ? Release(version: tag, items: []) : nil }
            } else if line.hasPrefix("- "), current != nil {
                current?.items.append(String(line.dropFirst(2)))
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// Words that tie a changelog line to this user's setup: what Meepo relies on, plus what their
    /// settings actually use. Plain matching — a hint, not a verdict.
    static func keywords(settings: [String: Any]) -> [String] {
        var words = ["hook", "statusline", "status line", "--settings", "--resume", "resume", "worktree", "effort",
                     "permission", "skill", "slash command", "auto mode", "claude.md", "memory", "background task"]
        if settings["mcpServers"] != nil || settings["enabledMcpjsonServers"] != nil { words.append("mcp") }
        if settings["enabledPlugins"] != nil { words.append("plugin") }
        if settings["outputStyle"] != nil { words.append("output style") }
        if settings["sandbox"] != nil { words.append("sandbox") }
        if let model = settings["model"] as? String { words.append(model.lowercased()) }
        return words
    }

    /// Lines that touch the setup first (in changelog order), then the rest.
    static func relevantFirst(_ items: [String], keywords: [String]) -> (relevant: [String], other: [String]) {
        var relevant: [String] = [], other: [String] = []
        for item in items {
            let lower = item.lowercased()
            if keywords.contains(where: lower.contains) { relevant.append(item) } else { other.append(item) }
        }
        return (relevant, other)
    }

    /// "2.1.282 (Claude Code)" → "2.1.282".
    static func version(fromCLI output: String) -> String? {
        output.split(separator: " ").first.map(String.init).flatMap { Updater.Version($0) != nil ? $0 : nil }
    }
}
