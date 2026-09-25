import Foundation

/// The user's skills and commands as Automations sees them: where each lives, whose it is, how often it's
/// used (from ~/.claude/history.jsonl — every prompt in every session, Meepo's or not), and its settings.
enum Automations {
    enum Owner: String { case personal = "Personal", team = "Team", builtIn = "Built into Claude Code" }

    struct Item: Identifiable, Equatable {
        let name: String
        let description: String?
        let file: URL?
        let owner: Owner
        /// Projects it's available in (empty = everywhere: personal ~/.claude or built-in).
        var projects: [String]
        var usage: Usage
        var effort: String?
        var model: String?
        var id: String { name }
    }

    struct Usage: Equatable {
        /// Uses per week, oldest first; the last element is the current week.
        var weekly: [Int]
        var lastUsed: Date?
        var total: Int { weekly.reduce(0, +) }
    }

    static let weeks = 8
    static let historyFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/history.jsonl")

    /// Slash-command uses from history.jsonl lines (`{"display":"/qa …","timestamp":ms,…}`), by command name.
    static func usage(historyLines: some Sequence<Substring>, now: Date = .now) -> [String: Usage] {
        var result: [String: Usage] = [:]
        let week: TimeInterval = 7 * 24 * 3600
        for line in historyLines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let display = obj["display"] as? String, display.hasPrefix("/"),
                  let ms = (obj["timestamp"] as? NSNumber)?.doubleValue else { continue }
            let name = String(display.dropFirst().prefix { !$0.isWhitespace })
            guard !name.isEmpty else { continue }
            let date = Date(timeIntervalSince1970: ms / 1000)
            var entry = result[name] ?? Usage(weekly: Array(repeating: 0, count: weeks), lastUsed: nil)
            let age = Int(now.timeIntervalSince(date) / week)
            if (0..<weeks).contains(age) { entry.weekly[weeks - 1 - age] += 1 }
            if entry.lastUsed.map({ date > $0 }) ?? true { entry.lastUsed = date }
            result[name] = entry
        }
        return result
    }

    /// Not used for `days` (or never): a candidate to fade out of the listing.
    static func isFading(_ item: Item, now: Date = .now, days: Double = 30) -> Bool {
        item.owner != .builtIn && (item.usage.lastUsed.map { now.timeIntervalSince($0) > days * 24 * 3600 } ?? true)
    }

    // MARK: Frontmatter

    /// `key: value` from a Markdown file's frontmatter.
    static func frontmatterValue(_ key: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        for line in lines[1..<end] where line.hasPrefix("\(key):") {
            let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Sets `key: value` (nil removes it), creating the frontmatter when there is none; the rest stays as it was.
    static func settingFrontmatter(_ key: String, to value: String?, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.first != "---" || lines.dropFirst().firstIndex(of: "---") == nil {
            guard let value else { return text }
            return (["---", "\(key): \(value)", "---"] + lines).joined(separator: "\n")
        }
        let end = lines.dropFirst().firstIndex(of: "---")!
        if let index = lines[1..<end].firstIndex(where: { $0.hasPrefix("\(key):") }) {
            if let value { lines[index] = "\(key): \(value)" } else { lines.remove(at: index) }
        } else if let value {
            lines.insert("\(key): \(value)", at: end)
        }
        return lines.joined(separator: "\n")
    }
}
