import Foundation

/// Hook events in plain words: "Ran git status", "Edited reports.go", "Asked your permission". A tool's start and
/// end become one line; the raw text stays one click away.
enum EventStory {
    struct Line: Identifiable, Equatable {
        /// The event the line stands for (the start of a tool, while it runs; its end, once done).
        let id: Int64
        let icon: String
        let title: String
        /// Everything the event said, shown when the line is opened.
        let detail: String?
        let date: Date
        /// A file the step read or changed.
        let file: String?
        let isRunning: Bool
        let isFailure: Bool
        let needsYou: Bool
        /// Claude Code's own message (a helper's report, a finished background task), not the user's: shown dim.
        var isQuiet = false

        /// The same step, no longer shown as running.
        var finished: Line {
            Line(id: id, icon: icon, title: title.hasSuffix("…") ? String(title.dropLast()) : title, detail: detail, date: date,
                 file: file, isRunning: false, isFailure: isFailure, needsYou: needsYou, isQuiet: isQuiet)
        }
    }

    /// Newest first, like the feed. A tool's start is dropped once the same call has ended.
    static func lines(_ events: [HookEvent]) -> [Line] {
        var result: [Line] = []
        // The same call can be open twice (parallel helpers, a denied call retried): an end closes the newest.
        var open: [String: [Int]] = [:]
        for event in events.sorted(by: { ($0.createdAt, $0.id ?? 0) < ($1.createdAt, $1.id ?? 0) }) {
            let key = event.summary ?? ""
            if ["PostToolUse", "PostToolUseFailure"].contains(event.name), let index = open[key]?.popLast() {
                result.remove(at: index)
                open = open.mapValues { $0.map { $0 > index ? $0 - 1 : $0 } }
            }
            if ["Stop", "StopFailure", "SessionEnd"].contains(event.name) {
                // The turn is over: a call that never reported its end (stopped, denied) isn't running any more.
                for index in open.values.joined() { result[index] = result[index].finished }
                open = [:]
            }
            guard let line = line(for: event) else { continue }
            if event.name == "PreToolUse" { open[key, default: []].append(result.count) }
            result.append(line)
        }
        return result.reversed()
    }

    /// One event on its own (the Deck's "now" line uses the latest).
    static func line(for event: HookEvent) -> Line? {
        let summary = event.summary.flatMap { $0.isEmpty ? nil : $0 }
        func make(_ icon: String, _ title: String, file: String? = nil, running: Bool = false, needsYou: Bool = false) -> Line {
            Line(id: event.id ?? 0, icon: icon, title: title, detail: summary, date: event.createdAt, file: file,
                 isRunning: running, isFailure: event.isFailure, needsYou: needsYou)
        }
        switch event.name {
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            let (tool, target) = split(summary ?? "")
            // A question's summary is the question itself — no "Tool: " in front. MCP names may carry hyphens
            // ("mcp__claude-in-chrome__navigate").
            guard tool.hasPrefix("mcp__") || tool.wholeMatch(of: #/[A-Za-z0-9_]+/#) != nil else {
                return make("questionmark.bubble", "Asked you: " + quote(summary), needsYou: event.name == "PreToolUse")
            }
            let phrase = toolPhrase(tool, target)
            if event.name == "PostToolUseFailure" { return make("exclamationmark.triangle", "Failed: " + phrase.title.lowercasedFirst, file: phrase.file) }
            return make(phrase.icon, event.name == "PreToolUse" ? phrase.title + "…" : phrase.title, file: phrase.file,
                        running: event.name == "PreToolUse")
        case "UserPromptSubmit":
            if let note = Runs.claudeCodeNote(summary ?? "") {
                var line = make("arrow.turn.down.right", note)
                line.isQuiet = true
                return line
            }
            return make("person", "You asked: " + quote(Runs.typed(summary ?? "")))
        case "UserPromptExpansion": return make("command", "Started " + quote(summary))
        case "Stop": return make("checkmark.bubble", "Claude replied")
        case "StopFailure": return make("xmark.octagon", "The reply failed")
        case "PermissionRequest": return make("hand.raised", "Asked your permission: " + quote(summary), needsYou: true)
        case "PermissionDenied": return make("hand.raised.slash", "Not allowed: " + quote(summary))
        case "Notification": return make("bell", "Waiting for you", needsYou: true)
        case "SessionStart": return make("play.circle", "Session started")
        case "SessionEnd": return make("stop.circle", "Session ended")
        case "PreCompact": return make("archivebox", "Tidied its memory (the conversation got long)")
        case "HookBlocked": return make("shield", "Your hook stopped a step: " + quote(summary))
        default: return summary == nil ? nil : make("circle", event.name)
        }
    }

    /// "Bash: git status" → ("Bash", "git status").
    static func split(_ summary: String) -> (tool: String, target: String?) {
        guard let colon = summary.range(of: ": ") else { return (summary, nil) }
        return (String(summary[..<colon.lowerBound]), String(summary[colon.upperBound...]))
    }

    static func toolPhrase(_ tool: String, _ target: String?) -> (icon: String, title: String, file: String?) {
        let name = target.map { URL(filePath: $0).lastPathComponent } ?? ""
        switch tool {
        case "Bash": return ("terminal", "Ran " + shortCommand(target ?? ""), nil)
        case "Edit", "MultiEdit", "NotebookEdit": return ("pencil", "Edited " + name, target)
        case "Write": return ("doc.badge.plus", "Wrote " + name, target)
        case "Read": return ("doc.text", "Read " + name, target)
        case "Grep", "Glob": return ("magnifyingglass", "Searched for " + quote(target), nil)
        case "WebFetch": return ("globe", "Opened " + (target.flatMap { URL(string: $0)?.host() } ?? "a web page"), nil)
        case "WebSearch": return ("globe", "Searched the web for " + quote(target), nil)
        case "Task", "Agent": return ("person.2", "Started a helper agent", nil)
        case "Skill": return ("sparkles", "Used /" + (target ?? "a skill"), nil)
        case "TodoWrite": return ("checklist", "Updated its to-do list", nil)
        case "AskUserQuestion": return ("questionmark.bubble", "Asked you: " + quote(target), nil)
        default: return ("wrench", "Used " + tool, nil)
        }
    }

    /// The part of a shell command that says what it does: `cd dir &&` prefixes go, long ones are cut.
    static func shortCommand(_ command: String) -> String {
        var parts = command.components(separatedBy: " && ").map { $0.trimmingCharacters(in: .whitespaces) }
        while parts.count > 1, parts[0].hasPrefix("cd ") { parts.removeFirst() }
        let first = parts.first ?? command
        let cut = first.count > 60 ? first.prefix(57) + "…" : Substring(first)
        return String(cut) + (parts.count > 1 ? " …" : "")
    }

    private static func quote(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "“" + (flat.count > 80 ? flat.prefix(77) + "…" : Substring(flat)) + "”"
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
