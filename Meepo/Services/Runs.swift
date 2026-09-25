import Foundation

/// One run of an agent: from the user's request to the real end of the work (a Stop with no background tasks
/// left), with the files it edited. Built from the hook events Meepo already keeps — nothing new to record.
struct Run: Identifiable, Equatable {
    let sessionId: Int64
    let startedAt: Date
    var endedAt: Date?
    let request: String
    var files: [String]
    var reply: String?
    var id: String { "\(sessionId)-\(startedAt.timeIntervalSince1970)" }
    var isDone: Bool { endedAt != nil }
}

/// What a run changed, in the product's terms — written by the agent that did the work, on the user's click.
struct ProductSummary: Codable, Equatable {
    struct Change: Codable, Equatable {
        /// "new", "changed", "fixed" or "removed".
        var kind: String
        /// What a user of the product can now do or will notice.
        var what: String
        /// Where in the product, e.g. "Driver app → Trips → Payment"; empty when it isn't visible to users.
        var where_: String

        enum CodingKeys: String, CodingKey { case kind, what, where_ = "where" }
    }

    var headline: String
    var changes: [Change]
    /// Open questions and risky spots to confirm before shipping.
    var check: [String]
    /// How to see it for yourself; empty when there's nothing to try.
    var howToTry: String

    enum CodingKeys: String, CodingKey { case headline, changes, check, howToTry = "how_to_try" }
}

enum Runs {
    /// Oldest first per session, newest run last. A Stop that still waits for background work doesn't end one.
    static func from(_ events: [HookEvent]) -> [Run] {
        var open: [Int64: Run] = [:]
        var runs: [Run] = []
        for event in events.sorted(by: { ($0.createdAt, $0.id ?? 0) < ($1.createdAt, $1.id ?? 0) }) {
            let id = event.sessionId
            switch event.name {
            case "UserPromptSubmit", "UserPromptExpansion":
                // "/qa" arrives as an expansion, then a submit of the same request: one run.
                if event.name == "UserPromptSubmit", let current = open[id], current.files.isEmpty { continue }
                if let current = open.removeValue(forKey: id) { runs.append(current) } // never saw its end
                open[id] = Run(sessionId: id, startedAt: event.createdAt, request: event.summary ?? "", files: [])
            case "PostToolUse":
                guard let summary = event.summary, let file = editedFile(summary) else { continue }
                if open[id] != nil, !(open[id]!.files.contains(file)) { open[id]!.files.append(file) }
            case "Stop":
                guard var current = open[id], !(event.summary ?? "").hasPrefix("Waiting for ") else { continue }
                current.endedAt = event.createdAt
                current.reply = event.summary
                runs.append(current)
                open[id] = nil
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

    /// The JSON Schema `claude -p --json-schema` checks the summary against.
    static let schema = """
        {"type":"object","properties":{
          "headline":{"type":"string"},
          "changes":{"type":"array","items":{"type":"object","properties":{
            "kind":{"type":"string","enum":["new","changed","fixed","removed"]},
            "what":{"type":"string"},"where":{"type":"string"}},"required":["kind","what","where"]}},
          "check":{"type":"array","items":{"type":"string"}},
          "how_to_try":{"type":"string"}},
         "required":["headline","changes","check","how_to_try"]}
        """

    static func prompt(for run: Run, language: String) -> String {
        """
        The user asked you: “\(run.request)”. Describe what your work since that request changed \
        for the people who use this product — not for developers. In \(language).
        - headline: one sentence, the change as a user would put it.
        - changes: each visible change: kind (new/changed/fixed/removed), what a user can now do or will notice, \
        and where in the product (screen or place, "A → B → C"); "where" is empty for changes users don't see.
        - check: open questions and risky spots to confirm before shipping (money, accounts, data, permissions, \
        anything you assumed); empty if none.
        - how_to_try: how the user can see it themselves; empty if there's nothing to try.
        No code, no file names, no invented details — only what you actually did in this conversation.
        """
    }
}
