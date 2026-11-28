import Foundation

/// Parallel sessions without chaos (2026-11-29): the other live sessions working in the same folder, and the files
/// each edited lately. A file a session edited is its claim: another session editing it asks first.
enum Neighbors {
    struct Neighbor: Equatable {
        var sessionId: Int64
        var name: String
        /// Absolute paths, the last edited first.
        var files: [String]
    }

    /// How long an edit keeps a file claimed by its session.
    static let claimWindow: TimeInterval = 2 * 3600

    /// What Claude reads on its next prompt, nil without neighbors.
    static func note(_ neighbors: [Neighbor], folder: String) -> String? {
        guard !neighbors.isEmpty else { return nil }
        let lines = neighbors.map { neighbor in
            let files = neighbor.files.prefix(8).map { relative($0, to: folder) }
            let more = neighbor.files.count > 8 ? ", +\(neighbor.files.count - 8) more" : ""
            return "- \"\(neighbor.name)\"" + (files.isEmpty ? " (no edits yet)" : ": edited \(files.joined(separator: ", "))\(more)")
        }
        return (["[meepo] Other Claude sessions work in this folder too:"] + lines
            + ["Leave their files alone; when you commit, stage only the files you changed yourself (git add <path>)."])
            .joined(separator: "\n")
    }

    /// Why editing `file` asks: a neighbor edited it lately. nil when nobody did.
    static func claimReason(file: String, neighbors: [Neighbor]) -> String? {
        guard let owner = neighbors.first(where: { $0.files.contains(file) }) else { return nil }
        return "Another session in this folder, \"\(owner.name)\", edited \((file as NSString).lastPathComponent) in the last "
            + "\(Int(claimWindow / 3600)) hours. Editing it here may undo its work."
    }

    /// A PreToolUse hook's answer that asks the person, with the reason (Claude Code's hook JSON).
    static func askOutput(_ reason: String) -> String {
        let output = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "ask",
                                             "permissionDecisionReason": reason]]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    private static func relative(_ path: String, to folder: String) -> String {
        path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path
    }
}
