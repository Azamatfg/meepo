import Foundation

/// DRAW: Claude explains something as one Mermaid diagram instead of text — easier to take in, tired or not.
/// A fresh `claude -p` (never a fork of the session: that re-reads the whole conversation) given only what it
/// needs: the last answer, the uncommitted diff, or a question it may answer by reading the code (read-only tools).
enum Diagram {
    enum Request: Hashable, Identifiable {
        /// Claude's latest answer in the session, drawn.
        case lastAnswer
        /// What the uncommitted changes do, and where.
        case changes
        /// How something in the project works; Claude reads the code to answer.
        case question(String)

        var id: Self { self }
    }

    struct Result: Codable, Equatable {
        let title: String
        let mermaid: String
        let caption: String
    }

    static let schema = #"{"type":"object","properties":{"title":{"type":"string"},"mermaid":{"type":"string"},"caption":{"type":"string"}},"required":["title","mermaid","caption"]}"#

    /// A question reads the project with these and nothing else: no edits, no shell.
    static let readOnlyTools = "Read,Grep,Glob"

    /// Longest diff sent: past this the picture wouldn't get better, only slower and dearer.
    static let diffLimit = 60_000

    /// The built-in tools claude -p gets: none, except for a question, which reads the project.
    static func tools(for request: Request) -> String {
        if case .question = request { readOnlyTools } else { "" }
    }

    static func prompt(_ request: Request, material: String, language: String) -> String {
        let what = switch request {
        case .lastAnswer: "the answer below, which Claude just gave in a coding session"
        case .changes: "what the uncommitted changes below do — which parts of the program they touch and how data flows through them"
        case let .question(question): "this, about the project in the current folder: \(question)\nRead the code you need (Read, Grep, Glob); change nothing."
        }
        return """
            Draw \(what) as ONE Mermaid diagram that someone tired can take in at a glance, instead of reading.
            - Pick the type that fits: flowchart LR for steps and flows, sequenceDiagram for who calls whom, erDiagram for data.
            - At most 15 nodes. Labels of 2–5 words, in \(language). Quote any label with punctuation: A["like this"].
            - No styling: no classDef, style, click or %% comments.
            Return title (at most 8 words, \(language)), mermaid (only the diagram code, no ``` fences), and caption
            (one or two plain sentences in \(language): the main point of the picture).
            \(material.isEmpty ? "" : "\n---\n" + material)
            """
    }

    /// The answer's diagram without the ``` fences a model sometimes adds anyway.
    static func cleaned(_ mermaid: String) -> String {
        var lines = mermaid.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
