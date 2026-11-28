import Foundation

/// Linked projects (2026-11-28): a backend and the app that calls it work as one. Each project names its contract
/// files — what the others depend on — and when a session changes one, the linked projects are told (after an ok).
enum Links {
    /// Whether `relative` (a path inside the project) matches `glob`: `*` within a folder, `**` across folders,
    /// a glob ending in "/" or naming a folder takes everything below it.
    static func matches(_ relative: String, _ glob: String) -> Bool {
        let glob = glob.trimmingCharacters(in: .whitespaces)
        guard !glob.isEmpty else { return false }
        if relative == glob || relative.hasPrefix(glob.hasSuffix("/") ? glob : glob + "/") { return true }
        var pattern = "^"
        var rest = Substring(glob)
        while let char = rest.first {
            if rest.hasPrefix("**/") { pattern += "(.*/)?"; rest = rest.dropFirst(3); continue }
            if rest.hasPrefix("**") { pattern += ".*"; rest = rest.dropFirst(2); continue }
            switch char {
            case "*": pattern += "[^/]*"
            case "?": pattern += "[^/]"
            default: pattern += NSRegularExpression.escapedPattern(for: String(char))
            }
            rest = rest.dropFirst()
        }
        return relative.range(of: pattern + "$", options: .regularExpression) != nil
    }

    /// The edited files (absolute) that are contract files of the project at `root`, relative to it.
    static func contractFiles(edited: [String], root: String, contracts: [String]) -> [String] {
        var found: [String] = []
        for file in edited where file.hasPrefix(root + "/") {
            let relative = String(file.dropFirst(root.count + 1))
            if contracts.contains(where: { matches(relative, $0) }), !found.contains(relative) { found.append(relative) }
        }
        return found
    }

    /// What a session of `project` reads once: who depends on its contracts, and whose contracts it depends on.
    static func note(project: Project, linked: [Project]) -> String? {
        guard !linked.isEmpty else { return nil }
        var lines = ["[meepo] \(project.name) is linked to other projects:"]
        for other in linked {
            var line = "- \(other.name) at \(other.path)"
            if let theirs = other.contractPaths, !theirs.isEmpty {
                line += "; \(project.name) depends on its contract files \(theirs.joined(separator: ", ")) — read them there for the API"
            }
            lines.append(line + ".")
        }
        if let own = project.contractPaths, !own.isEmpty {
            lines.append("They depend on \(project.name)'s contract files: \(own.joined(separator: ", ")). Change those only on purpose, "
                + "and say what changed in your answer: meepo offers to tell the linked projects.")
        }
        return lines.joined(separator: "\n")
    }

    /// What a linked project's session is told when `from` changed contract files.
    static func changeNote(from: Project, files: [String], folder: String) -> String {
        "[meepo] \(from.name) changed its contract: \(files.joined(separator: ", ")) (in \(folder)). "
            + "See what changed with `git -C \(folder) diff HEAD -- \(files.joined(separator: " "))` (not committed yet) "
            + "or `git -C \(folder) log -3 -p -- \(files.joined(separator: " "))`, then bring this project in line, or say why it needn't."
    }

    /// A task for a linked project nobody works in right now.
    static func task(from: Project, files: [String]) -> String {
        "Follow \(from.name)'s contract change: \(files.joined(separator: ", "))"
    }

    /// Likely contract files among the project's files (`git ls-files`): API specs, schemas, protos.
    static func suggestions(_ files: [String]) -> [String] {
        let names = /(^|\/)(openapi|swagger)[^\/]*\.(ya?ml|json)$|\.proto$|(^|\/)schema\.(graphql|gql)$|\.graphql$/
        let found = files.filter { $0.lowercased().contains(names) }
        // One glob for a folder of protos or graphql files, the file itself otherwise.
        var globs: [String] = []
        for file in found {
            let folder = (file as NSString).deletingLastPathComponent
            let ext = (file as NSString).pathExtension
            let sameKind = found.filter { ($0 as NSString).deletingLastPathComponent == folder && ($0 as NSString).pathExtension == ext }
            let glob = sameKind.count > 1 ? (folder.isEmpty ? "*.\(ext)" : "\(folder)/*.\(ext)") : file
            if !globs.contains(glob) { globs.append(glob) }
        }
        return Array(globs.prefix(8))
    }
}
