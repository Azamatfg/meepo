import Foundation

/// The workflow constructor's output: meepo runs nothing itself — each workflow becomes a plain Claude Code file
/// that works in any terminal. A button is a skill with the steps in order; "after every answer" is a Stop hook
/// that runs a check; repeating is `/loop`, the cloud is `/schedule`; parallel agents are Claude Code's own
/// saved workflows (`.claude/workflows/*.js`), which meepo only lists and starts.
enum Recipes {
    enum Step: Equatable, Hashable {
        /// A slash command or skill, without the slash.
        case command(String)
        /// Words for Claude.
        case prompt(String)

        var line: String {
            switch self {
            case let .command(name): "/" + name
            case let .prompt(text): text.split(whereSeparator: \.isNewline).joined(separator: " ")
            }
        }
    }

    // MARK: Buttons — skills

    /// A SKILL.md that runs the steps in order (checked live: a skill calls skills, built-in ones too, one after
    /// another). Only the user starts it; Claude stops at a question or a failure.
    static func skill(name: String, steps: [Step]) -> String {
        """
        ---
        name: \(name)
        description: \(yamlString("Runs " + steps.map(\.line).joined(separator: ", then ")))
        disable-model-invocation: true
        ---
        Run these steps in order. Start each one only after the one before it has fully finished.
        If a step asks the user something or fails, stop and tell the user; don't go on.

        \(steps.enumerated().map { "\($0.offset + 1). \($0.element.line)" }.joined(separator: "\n"))

        """
    }

    /// "New command…": the user's words as a skill. No `disable-model-invocation`: Claude has to be able to start it,
    /// or a workflow using it as a step stops there ("cannot be used with Skill tool due to disable-model-invocation").
    /// Its description is read into every conversation, so it's the first line of the words, kept short.
    static func command(name: String, instructions: String) -> String {
        let words = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = words.split(whereSeparator: \.isNewline).first.map(String.init) ?? name
        return """
            ---
            name: \(name)
            description: \(yamlString(first.count > 200 ? String(first.prefix(199)) + "…" : first))
            ---
            \(words)

            """
    }

    /// Why a new command of the user's can't be called `slug`; nil when it can. `taken`: every /name the user
    /// already has, theirs or a project's — a personal one of the same name would replace it.
    static func nameProblem(_ slug: String, taken: Set<String>) -> String? {
        if slug.isEmpty { return "The name needs latin letters or digits" }
        if CommandCatalog.claudeCodeNames.contains(slug) { return "/\(slug) is Claude Code's own command — pick another name" }
        if taken.contains(slug) { return "/\(slug) is taken — you or a project already have it. Pick another name" }
        return nil
    }

    /// What the step menu offers: commands Claude itself can start. Not meepo's buttons, not what's marked
    /// "only you" (in its file or by `skillOverrides`) or switched off there, not Claude Code screens like /plan —
    /// a skill calling one of those is refused, and the workflow stops there.
    static func stepChoices(_ commands: [SlashCommand], buttons: [String], overrides: [String: String]) -> [SlashCommand] {
        commands.filter { !$0.isUserOnly && !buttons.contains($0.name) && !["user-invocable-only", "off"].contains(overrides[$0.name]) }
    }

    /// The commands of a button that runs commands only, two or more — what Noticing calls a chain.
    static func chain(of steps: [Step]) -> [String]? {
        let names = steps.compactMap { if case let .command(name) = $0 { name } else { nil } }
        return names.count == steps.count && names.count > 1 ? names : nil
    }

    /// Every command the steps run exists among `available`; words for Claude always can.
    static func canRun(_ steps: [Step], with available: Set<String>) -> Bool {
        steps.allSatisfy { if case let .command(name) = $0 { available.contains(name) } else { true } }
    }

    /// A double-quoted YAML scalar (JSON's string escaping is valid YAML).
    static func yamlString(_ text: String) -> String {
        (try? JSONEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// The steps of a skill written by `skill(…)` — or of any skill that is a numbered list.
    static func steps(inSkill text: String) -> [Step] {
        text.components(separatedBy: "\n").compactMap { line in
            guard let match = line.firstMatch(of: #/^\d+\.\s+(.+)$/#) else { return nil }
            let body = String(match.1).trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("/"), !body.dropFirst().contains(where: \.isWhitespace) { return .command(String(body.dropFirst())) }
            return .prompt(body)
        }
    }

    /// A button's name for commands run in a row: "simplify-ship".
    static func buttonName(for commands: [String]) -> String { ClaudeLauncher.worktreeSlug(commands.joined(separator: "-")) }

    /// A name for a skill made from steps: "simplify-ship-sync".
    static func suggestedName(for steps: [Step]) -> String {
        steps.compactMap { if case let .command(name) = $0 { name } else { nil } }.prefix(3).joined(separator: "-")
    }

    /// Repeats a skill while the session stays open.
    static func loopCommand(skill: String, minutes: Int) -> String {
        minutes % 60 == 0 ? "/loop \(minutes / 60)h /\(skill)" : "/loop \(minutes)m /\(skill)"
    }

    /// Asks Claude Code's /schedule for a cloud routine. A cloud run sees the repo, not the user's own skills,
    /// so the steps are written out.
    static func scheduleRequest(steps: [Step], when: String) -> String {
        "/schedule \(when.trimmingCharacters(in: .whitespacesAndNewlines)), run these steps in order, "
            + "each after the one before finishes: "
            + steps.enumerated().map { "\($0.offset + 1)) \($0.element.line)" }.joined(separator: "; ")
    }

    // MARK: Checks after every answer — Stop hooks

    /// Settings JSON the way meepo writes it (BridgeInstaller), so a preview shows exactly what Save writes.
    static func settingsText(_ settings: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Marks the hooks meepo wrote for checks; `:` is the shell's no-op, so the marker costs nothing.
    static let checkMarker = ": meepo-check;"

    /// Runs `check` when Claude ends a turn with uncommitted changes. A failure blocks the stop (exit 2) and
    /// Claude reads the output and fixes it; Claude Code caps how often a Stop hook may block in a row.
    static func checkHookCommand(_ check: String) -> String {
        let quoted = "'" + check.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return "\(checkMarker) [ -n \"$(git status --porcelain 2>/dev/null)\" ] || exit 0; "
            + "out=$( {\n\(check)\n} 2>&1 ) && exit 0; "
            + "{ printf 'This check failed: %s\\nFix it, then finish.\\n' \(quoted); printf '%s\\n' \"$out\" | tail -n 40; } >&2; exit 2"
    }

    /// The check a hook command runs, if meepo wrote it.
    static func check(inHookCommand command: String) -> String? {
        guard command.hasPrefix(checkMarker),
              let match = command.firstMatch(of: #/out=\$\( \{\n(.+)\n\} 2>&1 \)/#) else { return nil }
        return String(match.1)
    }

    /// Checks in a settings file (`hooks.Stop[].hooks[]` written by meepo).
    static func checks(in settings: [String: Any]) -> [String] {
        stopGroups(settings).flatMap { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { ($0["command"] as? String).flatMap(check(inHookCommand:)) }
        }
    }

    /// Adds a check as its own Stop group; the user's other hooks stay as they are.
    static func addingCheck(_ check: String, to settings: [String: Any]) -> [String: Any] {
        guard !checks(in: settings).contains(check) else { return settings }
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let hook: [String: Any] = ["type": "command", "command": checkHookCommand(check), "timeout": 600]
        hooks["Stop"] = stopGroups(settings) + [["hooks": [hook]]]
        settings["hooks"] = hooks
        return settings
    }

    /// Takes one check out; a group left empty goes too.
    static func removingCheck(_ check: String, from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        let hooks = BridgeInstaller.removingHandlers(from: settings["hooks"] as? [String: Any] ?? [:]) {
            ($0["command"] as? String).flatMap(Self.check(inHookCommand:)) == check
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    private static func stopGroups(_ settings: [String: Any]) -> [[String: Any]] {
        (settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
    }

    // MARK: Saved workflows — Claude Code's own

    struct SavedWorkflow: Identifiable, Equatable {
        let name: String
        let description: String?
        let file: URL
        var id: String { file.path }
    }

    /// `.js` scripts in the given `workflows` folders, named by their `meta` (the file name when it has none).
    static func savedWorkflows(in folders: [URL]) -> [SavedWorkflow] {
        folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "js" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { file in
                    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                    return SavedWorkflow(name: metaValue("name", in: text) ?? file.deletingPathExtension().lastPathComponent,
                                         description: metaValue("description", in: text), file: file)
                }
        }
    }

    /// `name: '…'` inside `export const meta = {…}`.
    static func metaValue(_ key: String, in script: String) -> String? {
        guard let meta = script.firstMatch(of: #/export\s+const\s+meta\s*=\s*\{/#) else { return nil }
        let rest = script[meta.range.upperBound...]
        let pattern = try! Regex<(Substring, Substring, Substring)>(#"\b"# + key + #"\s*:\s*(['"`])(.*?)\1"#)
        return rest.firstMatch(of: pattern).map { String($0.output.2) }
    }

    /// What to type so Claude Code runs a saved workflow (asking by name is how the Workflow tool is started).
    static func runRequest(_ workflow: SavedWorkflow) -> String { "Run the saved workflow \(workflow.name)" }
}
