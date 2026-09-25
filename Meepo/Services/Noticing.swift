import Foundation

/// What Meepo notices in the user's own history (~/.claude/history.jsonl): commands run one after another again
/// and again, and the same request typed over and over. Plain counting — no model, no tokens.
enum Noticing {
    struct Entry: Equatable {
        let display: String
        let date: Date
        let session: String?
    }

    /// A pattern seen often enough to offer something for it.
    struct Suggestion: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Slash commands the user runs in this order: one button runs them all.
            case chain([String])
            /// A request typed again and again: worth a skill of its own.
            case skill(phrase: String)
        }

        let kind: Kind
        let count: Int

        var id: String {
            switch kind {
            case let .chain(commands): "chain:" + commands.joined(separator: ">")
            case let .skill(phrase): "skill:" + phrase
            }
        }
    }

    static let threshold = 5
    static let window: TimeInterval = 8 * 7 * 24 * 3600

    static func entries(historyLines: some Sequence<Substring>) -> [Entry] {
        historyLines.compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let display = obj["display"] as? String, let ms = (obj["timestamp"] as? NSNumber)?.doubleValue else { return nil }
            return Entry(display: display, date: Date(timeIntervalSince1970: ms / 1000), session: obj["sessionId"] as? String)
        }
        .sorted { $0.date < $1.date }
    }

    /// Runs of 2–3 different commands, in order, within one session. `known`: names that are skills or commands
    /// (so /exit, /usage and other CLI commands don't count). A pair already inside a reported triple isn't repeated.
    static func chains(_ entries: [Entry], known: Set<String>, since: Date) -> [Suggestion] {
        var bySession: [String: [String]] = [:]
        for entry in entries where entry.date >= since && entry.display.hasPrefix("/") {
            let name = String(entry.display.dropFirst().prefix { !$0.isWhitespace })
            guard known.contains(name), let session = entry.session else { continue }
            if bySession[session]?.last != name { bySession[session, default: []].append(name) }
        }
        var pairs: [[String]: Int] = [:], triples: [[String]: Int] = [:]
        for sequence in bySession.values {
            for i in sequence.indices.dropLast() {
                pairs[Array(sequence[i...i + 1]), default: 0] += 1
                if i + 2 < sequence.count, Set(sequence[i...i + 2]).count == 3 { triples[Array(sequence[i...i + 2]), default: 0] += 1 }
            }
        }
        let bigTriples = triples.filter { $0.value >= threshold }
        let covered = Set(bigTriples.keys.flatMap { [Array($0[0...1]), Array($0[1...2])] })
        let bigPairs = pairs.filter { $0.value >= threshold && !covered.contains($0.key) }
        return (bigTriples.merging(bigPairs) { a, _ in a })
            .map { Suggestion(kind: .chain($0.key), count: $0.value) }
            .sorted { ($0.count, $0.id) > ($1.count, $1.id) }
    }

    /// The same request typed at least `threshold` times. Pastes, paths, links and short replies ("да",
    /// "продолжим") aren't requests.
    static func repeatedPrompts(_ entries: [Entry], since: Date) -> [Suggestion] {
        var counts: [String: Int] = [:]
        for entry in entries where entry.date >= since {
            guard let phrase = normalized(entry.display) else { continue }
            counts[phrase, default: 0] += 1
        }
        return counts.filter { $0.value >= threshold }
            .map { Suggestion(kind: .skill(phrase: $0.key), count: $0.value) }
            .sorted { ($0.count, $0.id) > ($1.count, $1.id) }
    }

    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let skip = ["/", "[pasted", "[image", "'", "\"", "http", "~", "@"]
        guard !skip.contains(where: lower.hasPrefix), !lower.contains("/var/folders"),
              trimmed.count >= 12, trimmed.count <= 200 else { return nil }
        return lower.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: "))
    }

    // MARK: Measuring

    /// Uses per week of `/command` in the `weeks` before `date`, and since it (nil until a week has passed).
    static func rate(of command: String, in entries: [Entry], around date: Date, weeksBefore: Double = 4,
                     now: Date = .now) -> (before: Double, after: Double?) {
        let week: TimeInterval = 7 * 24 * 3600
        let uses = entries.filter { $0.display == "/" + command || $0.display.hasPrefix("/" + command + " ") }
        let before = Double(uses.filter { $0.date < date && $0.date >= date.addingTimeInterval(-weeksBefore * week) }.count) / weeksBefore
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= week else { return (before, nil) }
        return (before, Double(uses.filter { $0.date >= date }.count) / (elapsed / week))
    }

    /// Things Meepo itself now does, the command each one should make less needed, and since when —
    /// Meepo checks its own changes against the user's real behavior.
    static let meepoReplacements: [(command: String, feature: String, since: Date)] = [
        ("usage", "Plan limits in Meepo's status bar (0.2.3)", Date(timeIntervalSince1970: 1_790_345_945)),
    ]
}
