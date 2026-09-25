import Foundation

/// A slash command available in a project: its own `.claude/commands` / `.claude/skills`,
/// the user's global ones in `~/.claude`, and Claude Code built-ins used as stages.
struct SlashCommand: Hashable, Identifiable {
    var name: String
    var description: String?
    var id: String { name }
}

enum CommandCatalog {
    /// Built-ins that ship with Claude Code and serve as workflow stages (names checked in 2.1.282).
    static let builtIns = [
        SlashCommand(name: "plan", description: "Plan mode: read and plan, no edits"),
        SlashCommand(name: "simplify", description: "Review changed code for reuse, quality and efficiency"),
        SlashCommand(name: "verify", description: "Check that the change actually works"),
        SlashCommand(name: "code-review", description: "Review the changes"),
        SlashCommand(name: "security-review", description: "Security review of the pending changes on this branch"),
        SlashCommand(name: "commit-push-pr", description: "Commit, push and open a pull request"),
    ]

    /// A stage's own command → the built-in that does its job when a project has no such command,
    /// so a teammate without anyone's .claude folder still has working stages.
    static let standIns = ["qa": "verify", "security": "security-review", "ship": "commit-push-pr"]

    /// The command a stage runs given the commands a project has: its own, else its built-in stand-in.
    static func resolve(_ command: String, available: Set<String>) -> String? {
        if available.contains(command) { return command }
        return standIns[command].flatMap { available.contains($0) ? $0 : nil }
    }

    /// Project entries override global ones of the same name; sorted by name.
    static func commands(projectPath: String,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SlashCommand] {
        var byName: [String: SlashCommand] = [:]
        for command in builtIns { byName[command.name] = command }
        for dir in [home.appending(path: ".claude"), URL(filePath: projectPath).appending(path: ".claude")] {
            for command in scan(dir) { byName[command.name] = command }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// `commands/**/*.md` (subfolders become "dir:name", as Claude Code names them) and `skills/*/SKILL.md`.
    private static func scan(_ claudeDir: URL) -> [SlashCommand] {
        var result: [SlashCommand] = []
        let commandsDir = claudeDir.appending(path: "commands")
        // Relative paths from the enumerator itself: comparing absolute prefixes breaks on /var vs /private/var.
        if let files = FileManager.default.enumerator(atPath: commandsDir.path) {
            for case let relative as String in files where relative.hasSuffix(".md") {
                result.append(SlashCommand(name: relative.dropLast(3).replacingOccurrences(of: "/", with: ":"),
                                           description: description(of: commandsDir.appending(path: relative))))
            }
        }
        let skillsDir = claudeDir.appending(path: "skills")
        for skill in (try? FileManager.default.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil)) ?? [] {
            let file = skill.appending(path: "SKILL.md")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            result.append(SlashCommand(name: skill.lastPathComponent, description: description(of: file)))
        }
        return result
    }

    /// `description:` from YAML frontmatter; without it, the first line of the body (as Claude Code does),
    /// e.g. "# Investigate — debug a bug" → "Investigate — debug a bug".
    static func description(of file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        if lines.first?.hasPrefix("---") == true {
            lines = lines.dropFirst()
            while let line = lines.first, !line.hasPrefix("---") {
                if line.hasPrefix("description:") {
                    let value = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                    return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                lines = lines.dropFirst()
            }
            lines = lines.dropFirst()
        }
        let first = lines.lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return first.map { $0.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression) }
    }
}

/// One step of the user's workflow (SPEC module 4), e.g. plan → code → qa → ship → sync.
struct Stage: Codable, Hashable, Identifiable {
    var name: String
    /// Slash command that starts the stage; nil for "code" (just talking to Claude).
    var command: String?
    /// Used only when a new session starts in this stage (switching mid-session would drop the prompt cache).
    var model: String?
    var effort: String?
    var id: String { name }

    var label: String { String(name.uppercased().prefix(4)) }

    /// SPEC §10: plan on the strongest model with maximum reasoning, implementation on the default.
    static let defaults: [Stage] = [
        Stage(name: "plan", command: "plan", model: "opus", effort: "max"),
        Stage(name: "code", command: nil),
        Stage(name: "qa", command: "qa"),
        Stage(name: "security", command: "security"),
        Stage(name: "simplify", command: "simplify"),
        Stage(name: "ship", command: "ship"),
        Stage(name: "sync", command: "sync"),
    ]
}
