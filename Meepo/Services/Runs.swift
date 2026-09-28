import Foundation

/// One run of an agent: from the user's request to the real end of the work (a Stop with no background tasks
/// left), with the files it edited. Built from the hook events Meepo already keeps — nothing new to record.
struct Run: Identifiable, Equatable {
    let sessionId: Int64
    let startedAt: Date
    var endedAt: Date?
    /// What the user typed; a paste reads "[pasted 36 lines]".
    let request: String
    var files: [String]
    /// Claude's answer; while background work still runs, what it has said so far.
    var reply: String?
    var id: String { "\(sessionId)-\(startedAt.timeIntervalSince1970)" }
    var isDone: Bool { endedAt != nil }

    enum Outcome { case working, askedYou, done, noReply }

    /// Still working, ended with a question for the user, done — or the user's next message (or the reply failing,
    /// or the session closing) came before Claude's answer. That isn't "stopped": the hook can't tell Esc from a
    /// message sent while Claude worked (UserPromptSubmit carries only the prompt and the session's title).
    var outcome: Outcome {
        guard isDone else { return .working }
        guard reply != nil else { return .noReply }
        return question != nil ? .askedYou : .done
    }

    /// The answer in a line or two: its first paragraph as plain text.
    var gist: String? { reply.flatMap(Runs.gist) }

    /// The question a finished answer ends on (the last "?" of its last paragraph), e.g. "Закоммитить и запушить?".
    var question: String? { isDone ? reply.flatMap(Runs.question) : nil }

    /// How long Claude worked on it — until now while it still runs.
    func worked(now: Date = .now) -> TimeInterval { (endedAt ?? now).timeIntervalSince(startedAt) }
}

enum Runs {
    /// Oldest first per session, newest run last. A Stop that still waits for background work doesn't end one,
    /// and Claude Code's own turns (a helper's report, a finished background task) carry the open run on.
    static func from(_ events: [HookEvent]) -> [Run] {
        var open: [Int64: Run] = [:]
        var runs: [Run] = []
        for event in events.sorted(by: { ($0.createdAt, $0.id ?? 0) < ($1.createdAt, $1.id ?? 0) }) {
            let id = event.sessionId
            switch event.name {
            case "UserPromptSubmit", "UserPromptExpansion":
                guard let request = typed(event.summary ?? "") else { continue }
                // "/qa" arrives as an expansion, then a submit of the same request, moments apart: one run.
                if event.name == "UserPromptSubmit", let current = open[id], current.request == request, current.files.isEmpty,
                   event.createdAt.timeIntervalSince(current.startedAt) < 5 { continue }
                if var current = open.removeValue(forKey: id) { // the next message came first: it ends here
                    current.endedAt = event.createdAt
                    runs.append(current)
                }
                open[id] = Run(sessionId: id, startedAt: event.createdAt, request: request, files: [])
            case "PostToolUse":
                guard let summary = event.summary, let file = editedFile(summary) else { continue }
                if open[id] != nil, !(open[id]!.files.contains(file)) { open[id]!.files.append(file) }
            case "Stop":
                guard var current = open[id] else { continue }
                let summary = event.summary ?? ""
                if summary.hasPrefix("Waiting for ") {
                    // "Waiting for 4 background tasks · Started four reviews": the answer so far.
                    if let dot = summary.range(of: " · ") { current.reply = String(summary[dot.upperBound...]) }
                    open[id] = current
                    continue
                }
                current.endedAt = event.createdAt
                current.reply = event.summary
                runs.append(current)
                open[id] = nil
            case "StopFailure", "SessionEnd":
                // The reply failed, or the session closed mid-request: it ends here instead of "working" for days.
                guard var current = open.removeValue(forKey: id) else { continue }
                current.endedAt = event.createdAt
                runs.append(current)
            default:
                continue
            }
        }
        return (runs + open.values).sorted { $0.startedAt < $1.startedAt }
    }

    /// "Edit: /path/to/file.swift" → "/path/to/file.swift".
    static func editedFile(_ summary: String) -> String? {
        for tool in ["Edit", "Write", "MultiEdit", "NotebookEdit"] where summary.hasPrefix(tool + ": ") {
            return String(summary.dropFirst(tool.count + 2))
        }
        return nil
    }

    // MARK: What the user typed, and what Claude Code sent on its own

    /// Tags Claude Code wraps its own messages in when it hands them to Claude as a turn — they reach the
    /// UserPromptSubmit hook like a prompt, but nobody typed them (Claude Code 2.1.283's list).
    static let claudeCodeTags: Set = [
        "task-notification", "agent-message", "teammate-message", "cross-session-message", "channel", "tick",
        "remote-review", "remote-review-progress", "slack-ping", "slack-tag-message", "fetched-web-content",
        "coordinator-relay", "artifact-type-instructions", "cowritten-artifact-html", "artifact-file-content",
        "artifact-origin-notes", "artifact-stored-declaration",
    ]

    /// The tag of a turn Claude Code sent on its own ("task-notification"); nil for what the user typed.
    static func claudeCodeTag(_ prompt: String) -> String? {
        let text = prompt.drop { $0.isWhitespace }
        guard let match = text.prefixMatch(of: /<([a-z][a-z0-9_-]*)[\s>]/) else { return nil }
        let tag = String(match.1)
        return claudeCodeTags.contains(tag) ? tag : nil
    }

    /// What the user typed, pastes folded to "[pasted 36 lines]"; nil for Claude Code's own turns.
    static func typed(_ prompt: String) -> String? {
        guard claudeCodeTag(prompt) == nil else { return nil }
        let folded = prompt.replacing(/<pasted_content[^>]*>(.*?)<\/pasted_content[^>]*>/.dotMatchesNewlines()) { match in
            let lines = match.1.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false).count
            return "[pasted \(lines) line\(lines == 1 ? "" : "s")]"
        }
        return folded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Claude Code turn in plain words, for the feed: "Helper “Simplification review” finished".
    static func claudeCodeNote(_ prompt: String) -> String? {
        guard let tag = claudeCodeTag(prompt) else { return nil }
        switch tag {
        case "task-notification":
            let summary = prompt.firstMatch(of: /<summary>(.*?)<\/summary>/.dotMatchesNewlines()).map { String($0.1) }
            guard let summary, !summary.isEmpty else { return "A background task finished" }
            return summary.replacing(/^Agent "(.*?)"/) { "Helper “\($0.1)”" }
        case "agent-message": return "A helper's report came in"
        case "teammate-message": return "A message from a teammate agent"
        case "cross-session-message": return "A message from another Claude session"
        case "tick": return "Claude Code's timer woke Claude up"
        default: return "Claude Code passed on a message (\(tag))"
        }
    }

    // MARK: The answer

    /// The first paragraph of an answer as plain text, cut to a readable length. A heading on a line of its own
    /// ("## Итог") says nothing yet: the paragraph after it is the gist.
    static func gist(_ reply: String) -> String? {
        paragraphs(reply).lazy.filter { !($0.hasPrefix("#") && !$0.contains("\n")) }
            .map { Notifier.plainText($0, limit: 200) }.first { !$0.isEmpty }
    }

    /// The sentence ending on the last "?" of the answer's last paragraph; nil when it doesn't ask anything.
    /// A "?" inside a word or a link ("?a=1") doesn't count.
    static func question(_ reply: String) -> String? {
        guard let last = paragraphs(reply).last else { return nil }
        let asks = last.matches(of: /[?？](?=$|[\s)»"”*_])/).last
        guard let end = asks?.range.upperBound else { return nil }
        let upTo = last[..<end]
        let start = upTo.dropLast().matches(of: /[.!?？…](?:\s+)|\n/).last?.range.upperBound ?? upTo.startIndex
        let sentence = Notifier.plainText(String(upTo[start...]), limit: 200)
        return sentence.isEmpty ? nil : sentence
    }

    private static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
