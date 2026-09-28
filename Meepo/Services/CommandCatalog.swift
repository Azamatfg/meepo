import Foundation

/// A slash command available in a project: its own `.claude/commands` / `.claude/skills`,
/// the user's global ones in `~/.claude`, and Claude Code built-ins used as stages.
struct SlashCommand: Hashable, Identifiable {
    var name: String
    var description: String?
    /// The Markdown file it comes from; nil for Claude Code built-ins.
    var file: URL?
    /// Only the user can start it: `disable-model-invocation: true` in its file, or a Claude Code screen like /plan.
    /// Claude can't run it, so it can't be a step of a workflow (the Skill tool refuses it).
    var isUserOnly = false
    var id: String { name }
    var isSkill: Bool { file?.lastPathComponent == "SKILL.md" }
}

enum CommandCatalog {
    /// Built-ins that ship with Claude Code and serve as workflow stages (names checked in 2.1.282).
    static let builtIns = [
        // A screen of Claude Code's own (local-jsx in 2.1.283), not a skill: Claude can't start it.
        SlashCommand(name: "plan", description: "Plan mode: read and plan, no edits", isUserOnly: true),
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

    /// What `/name` runs in this project, one per name, sorted by name. Claude Code takes the first it finds in this
    /// order (2.1.283, checked live): your skills, the project's skills, your commands, the project's commands, then
    /// its own. So your ~/.claude/commands/ship.md replaces a project's .claude/commands/ship.md — not the other way.
    static func commands(projectPath: String,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SlashCommand] {
        let personal = home.appending(path: ".claude"), project = URL(filePath: projectPath).appending(path: ".claude")
        var seen: Set<String> = []
        return (skills(in: personal) + skills(in: project) + commands(in: personal) + commands(in: project) + builtIns)
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name < $1.name }
    }

    /// `commands/**/*.md`; subfolders become "dir:name", as Claude Code names them.
    private static func commands(in claudeDir: URL) -> [SlashCommand] {
        let commandsDir = claudeDir.appending(path: "commands")
        // Relative paths from the enumerator itself: comparing absolute prefixes breaks on /var vs /private/var.
        guard let files = FileManager.default.enumerator(atPath: commandsDir.path) else { return [] }
        return files.compactMap { relative in
            guard let relative = relative as? String, relative.hasSuffix(".md") else { return nil }
            return command(relative.dropLast(3).replacingOccurrences(of: "/", with: ":"), commandsDir.appending(path: relative))
        }
    }

    /// `skills/*/SKILL.md`.
    private static func skills(in claudeDir: URL) -> [SlashCommand] {
        let skillsDir = claudeDir.appending(path: "skills")
        return ((try? FileManager.default.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appending(path: "SKILL.md") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { command($0.deletingLastPathComponent().lastPathComponent, $0) }
    }

    private static func command(_ name: String, _ file: URL) -> SlashCommand {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return SlashCommand(name: name, description: description(in: text), file: file,
                            isUserOnly: Automations.frontmatterValue("disable-model-invocation", in: text) == "true")
    }

    /// Names Claude Code itself answers to (its commands and bundled skills, 2.1.283). A command of yours with one of
    /// these names would hide Claude Code's own or never run, so meepo doesn't make one.
    static let claudeCodeNames: Set<String> = [
        "add-dir", "advisor", "agents", "artifacts", "autocompact", "batch", "branch", "btw", "bug", "chrome", "claude-api",
        "clear", "code-review", "color", "commit", "commit-push-pr", "compact", "config", "context", "copy", "cost",
        "debug", "desktop", "diff", "doctor", "effort", "exit", "export", "fast", "feedback", "fewer-permission-prompts",
        "focus", "fork", "goal", "help", "hooks", "ide", "import", "init", "insights", "install-github-app",
        "keybindings", "keybindings-help", "login", "logout", "loop", "loops", "mcp", "memory", "mobile", "model",
        "output-style", "permissions", "plan", "plugin", "pr", "privacy-settings", "recap",
        "release-notes", "reload-plugins", "reload-skills", "remote-control", "remote-env", "rename", "resume", "review",
        "rewind", "run", "sandbox", "schedule", "security-review", "session", "simplify", "skills", "stats", "status",
        "statusline", "stickers", "tasks", "teleport", "terminal-setup", "theme", "todos", "ultraplan", "ultrareview",
        "update", "update-config", "upgrade", "usage", "verify", "voice", "workflows",
    ]

    /// `description:` from YAML frontmatter; without it, the first line of the body (as Claude Code does),
    /// e.g. "# Investigate — debug a bug" → "Investigate — debug a bug".
    static func description(in text: String) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        if lines.first?.hasPrefix("---") == true {
            lines = lines.dropFirst()
            while let line = lines.first, !line.hasPrefix("---") {
                if line.hasPrefix("description:") {
                    let value = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                    // A double-quoted value may carry escapes (`\"`, and `\/` from meepo 0.5's buttons).
                    if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\""),
                       let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) { return decoded }
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

    /// A hidden default stage back in the bar, where it stands in the default order.
    static func adding(_ stage: Stage, to stages: [Stage]) -> [Stage] {
        let rank = { (name: String) in defaults.firstIndex { $0.name == name } ?? defaults.count }
        var result = stages.filter { $0.name != stage.name }
        let index = result.firstIndex { rank($0.name) > rank(stage.name) } ?? result.count
        result.insert(stage, at: index)
        return result
    }
}
