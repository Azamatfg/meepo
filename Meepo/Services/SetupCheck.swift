import Foundation

/// Things in the user's Claude Code setup that quietly work against them, each with a fix and its exact undo.
/// Only the user's own files (~/.claude); a project's files under git are the team's and never touched.
enum SetupCheck {
    struct Finding: Identifiable {
        let id: String
        let title: String
        let detail: String
        let fixTitle: String
        let fix: Fix
    }

    enum Fix {
        /// A change to ~/.claude/settings.json and the change that takes it back.
        case settings(apply: (inout [String: Any]) -> Void, undo: (inout [String: Any]) -> Void)
        /// Add `disable-model-invocation: true` to a skill or command so only the user can start it.
        case manualOnly(URL)
    }

    /// Allow rules that let Claude run anything of a kind without asking.
    static let broadRules = ["Bash", "Bash(*)", "Bash(sudo:*)", "Bash(bash:*)", "Bash(sh:*)", "Bash(zsh:*)",
                             "Bash(eval:*)", "Bash(curl:*)", "Bash(rm:*)", "Bash(sudo *)", "Bash(curl *)", "Bash(rm *)"]

    /// `topModel`: the model the user uses most (from usage). `commands`: their own skills and commands.
    static func findings(settings: [String: Any], topModel: String?, commands: [(url: URL, text: String)]) -> [Finding] {
        effort(settings, topModel) + hookTimeouts(settings) + broadPermissions(settings) + unguardedShipping(commands)
    }

    /// Claude Code 2.1.280: an `effortLevel` saved before effort became per-model doesn't apply to newer models
    /// (Opus 5.5…); they run at their default until a level is set for them.
    static func effort(_ settings: [String: Any], _ model: String?) -> [Finding] {
        guard let model, let level = settings["effortLevel"] as? String,
              ((settings["modelSettings"] as? [String: Any])?[model] as? [String: Any])?["effortLevel"] == nil else { return [] }
        return [Finding(
            id: "effort-\(model)",
            title: "\(model) ignores your effort setting",
            detail: "settings.json asks for effort \(level), but since Claude Code 2.1.280 that only reaches models that had it set before. \(model) — the model you use most — runs at its default.",
            fixTitle: "Use \(level) for \(model)",
            fix: .settings(apply: { settings in
                var models = settings["modelSettings"] as? [String: Any] ?? [:]
                var entry = models[model] as? [String: Any] ?? [:]
                entry["effortLevel"] = level
                models[model] = entry
                settings["modelSettings"] = models
            }, undo: { settings in
                var models = settings["modelSettings"] as? [String: Any] ?? [:]
                var entry = models[model] as? [String: Any] ?? [:]
                entry["effortLevel"] = nil
                models[model] = entry.isEmpty ? nil : entry
                settings["modelSettings"] = models.isEmpty ? nil : models
            })
        )]
    }

    /// Hook timeouts are seconds; 1000 and up almost always meant milliseconds (10000 = 2.8 hours of waiting).
    static func hookTimeouts(_ settings: [String: Any]) -> [Finding] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var result: [Finding] = []
        for (event, value) in hooks.sorted(by: { $0.key < $1.key }) {
            for (g, group) in ((value as? [[String: Any]]) ?? []).enumerated() {
                for (h, handler) in ((group["hooks"] as? [[String: Any]]) ?? []).enumerated() {
                    guard let timeout = (handler["timeout"] as? NSNumber)?.intValue, timeout >= 1000 else { continue }
                    let seconds = timeout / 1000
                    let command = (handler["command"] as? String).map { " (\(String($0.prefix(60))))" } ?? ""
                    result.append(Finding(
                        id: "timeout-\(event)-\(g)-\(h)",
                        title: "A \(event) hook may hang for \(duration(timeout))",
                        detail: "Its timeout is \(timeout) — Claude Code reads that as seconds. It looks like milliseconds were meant\(command).",
                        fixTitle: "Set \(seconds) s",
                        fix: .settings(apply: { setTimeout(&$0, event, g, h, from: timeout, to: seconds) },
                                       undo: { setTimeout(&$0, event, g, h, from: seconds, to: timeout) })
                    ))
                }
            }
        }
        return result
    }

    static func broadPermissions(_ settings: [String: Any]) -> [Finding] {
        let allow = ((settings["permissions"] as? [String: Any])?["allow"] as? [String]) ?? []
        return allow.filter(broadRules.contains).map { rule in
            Finding(
                id: "allow-\(rule)",
                title: "Claude may run \(rule) without asking",
                detail: "This allow rule in settings.json covers every command of that kind in every project, including destructive ones. Auto mode's checks don't look at commands an allow rule already lets through.",
                fixTitle: "Remove the rule",
                fix: .settings(apply: { editAllow(&$0) { $0.removeAll { $0 == rule } } },
                               undo: { editAllow(&$0) { if !$0.contains(rule) { $0.append(rule) } } })
            )
        }
    }

    /// A skill or command that commits or pushes, which Claude may also start on its own.
    static func unguardedShipping(_ commands: [(url: URL, text: String)]) -> [Finding] {
        commands.filter { command in
            let text = command.text
            return (text.contains("git push") || text.contains("git commit"))
                && !frontmatter(of: text).contains { $0.hasPrefix("disable-model-invocation:") && $0.hasSuffix("true") }
        }.map { command in
            let name = command.url.lastPathComponent == "SKILL.md" ? command.url.deletingLastPathComponent().lastPathComponent
                : command.url.deletingPathExtension().lastPathComponent
            return Finding(
                id: "manual-\(command.url.path)",
                title: "Claude can run /\(name) by itself",
                detail: "It commits or pushes, and nothing stops Claude from starting it without you. disable-model-invocation keeps it yours to run.",
                fixTitle: "Only I start it",
                fix: .manualOnly(command.url)
            )
        }
    }

    /// Adds (or removes) `disable-model-invocation: true` in a Markdown file's frontmatter.
    static func setManualOnly(_ text: String, _ on: Bool) -> String {
        let line = "disable-model-invocation: true"
        var lines = text.components(separatedBy: "\n")
        if on {
            if lines.first == "---" { lines.insert(line, at: 1) } else { lines.insert(contentsOf: ["---", line, "---"], at: 0) }
        } else if let index = lines.firstIndex(of: line) {
            lines.remove(at: index)
            if lines.count >= 2, lines[0] == "---", lines[1] == "---" { lines.removeFirst(2) }
        }
        return lines.joined(separator: "\n")
    }

    /// The user's own skills and commands: ~/.claude/commands/**.md and ~/.claude/skills/*/SKILL.md.
    static func userCommands(claudeHome: URL) -> [(url: URL, text: String)] {
        var files: [URL] = []
        let commands = claudeHome.appending(path: "commands")
        if let enumerator = FileManager.default.enumerator(atPath: commands.path) {
            for case let relative as String in enumerator where relative.hasSuffix(".md") { files.append(commands.appending(path: relative)) }
        }
        let skills = claudeHome.appending(path: "skills")
        for skill in (try? FileManager.default.contentsOfDirectory(at: skills, includingPropertiesForKeys: nil)) ?? [] {
            files.append(skill.appending(path: "SKILL.md"))
        }
        return files.compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url, $0) } }
    }

    // MARK: Helpers

    private static func frontmatter(of text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [] }
        return lines[1..<end].map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func duration(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%.1f hours", Double(seconds) / 3600) : "\(seconds / 60) minutes"
    }

    /// Only when the value is still what the fix expects — a later hand edit wins.
    private static func setTimeout(_ settings: inout [String: Any], _ event: String, _ g: Int, _ h: Int, from: Int, to: Int) {
        guard var hooks = settings["hooks"] as? [String: Any], var groups = hooks[event] as? [[String: Any]],
              groups.indices.contains(g), var handlers = groups[g]["hooks"] as? [[String: Any]], handlers.indices.contains(h),
              (handlers[h]["timeout"] as? NSNumber)?.intValue == from else { return }
        handlers[h]["timeout"] = to
        groups[g]["hooks"] = handlers
        hooks[event] = groups
        settings["hooks"] = hooks
    }

    private static func editAllow(_ settings: inout [String: Any], _ change: (inout [String]) -> Void) {
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        change(&allow)
        permissions["allow"] = allow
        settings["permissions"] = permissions
    }
}
