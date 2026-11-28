import Foundation

/// What Claude reads in a project besides the conversation (2026-11-28): CLAUDE.md files and rules — when each loads,
/// what it costs — and the project's auto memory, with what's wrong in it and what makes the context heavy.
/// Read from disk off the main thread; `ContextPanel` shows it.
enum Sources {
    enum Loading: Equatable {
        /// Every turn of every session in the project.
        case always
        /// A rule with `paths:` — when Claude reads a matching file.
        case paths([String])
        /// A CLAUDE.md in a folder below — when Claude reads a file there.
        case nested
    }

    struct Instruction: Equatable {
        var path: String
        /// "user", "parent", "project", "local".
        var scope: String
        var loading: Loading
        var tokens: Int
        /// Exact (Claude Code's count, the file is in this session's context) or estimated from its size.
        var isMeasured: Bool
        var isLoaded: Bool
    }

    struct MemoryEntry: Equatable {
        /// The file's name in the memory folder ("feedback_x.md").
        var file: String
        var title: String
        var hook: String
        var isIndexed: Bool
        var exists: Bool
    }

    struct Memory: Equatable {
        var folder: String
        var index: String
        var indexLines: Int
        var entries: [MemoryEntry]
        /// [[links]] to memories not written yet — allowed, shown only as a count.
        var unwritten: [String]
    }

    struct Hint: Equatable {
        var text: String
        var path: String?
    }

    /// Claude Code reads only the start of MEMORY.md.
    static let memoryIndexLimit = 200
    static let heavyInstruction = 2000
    /// A rule shorter than this is fine without paths: ("commit in English" is for every file).
    static let pathlessRuleHint = 300

    /// ≈ tokens of a file Claude Code hasn't measured: about four characters a token.
    static func estimate(_ text: String) -> Int { max(1, text.count / 4) }

    // MARK: Instructions

    /// `folder`: where claude runs; `tracked`: its CLAUDE.md files as `git ls-files` lists them (relative);
    /// `measured`: path → tokens of the files in the session's context; `loaded`: files Claude Code reported loading.
    static func instructions(folder: String, home: String, tracked: [String], measured: [String: Int], loaded: Set<String>,
                             read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
                             list: (String) -> [String] = Self.markdownFiles) -> [Instruction] {
        var result: [Instruction] = []
        func add(_ path: String, _ scope: String, _ loading: Loading, text: String? = nil) {
            guard !result.contains(where: { $0.path == path }), let text = text ?? read(path) else { return }
            let exact = measured[path]
            result.append(Instruction(path: path, scope: scope, loading: loading, tokens: exact ?? estimate(text),
                                      isMeasured: exact != nil, isLoaded: exact != nil || loaded.contains(path)))
        }
        func rules(in dir: String, _ scope: String) {
            for file in list(dir) {
                guard let text = read(file) else { continue }
                let paths = rulePaths(text)
                add(file, scope, paths.isEmpty ? .always : .paths(paths), text: text)
            }
        }
        add("\(home)/.claude/CLAUDE.md", "user", .always)
        rules(in: "\(home)/.claude/rules", "user")
        // Folders above the project, up to (not including) the home folder: Claude Code reads their CLAUDE.md too.
        var parent = (folder as NSString).deletingLastPathComponent
        while parent.hasPrefix(home + "/") {
            add("\(parent)/CLAUDE.md", "parent", .always)
            parent = (parent as NSString).deletingLastPathComponent
        }
        add("\(folder)/CLAUDE.md", "project", .always)
        add("\(folder)/.claude/CLAUDE.md", "project", .always)
        add("\(folder)/CLAUDE.local.md", "local", .always)
        rules(in: "\(folder)/.claude/rules", "project")
        for file in tracked.sorted() where file.contains("/") && !file.hasPrefix(".claude/") {
            add("\(folder)/\(file)", "project", .nested)
        }
        return result
    }

    /// A rule's `paths:` from its frontmatter: a list (`- "src/**"`) or one line (`paths: src/**, lib/**`).
    static func rulePaths(_ text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }
        var paths: [String] = [], inPaths = false
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.hasPrefix("paths:") {
                let rest = trimmed.dropFirst("paths:".count).trimmingCharacters(in: .whitespaces)
                inPaths = rest.isEmpty
                if !rest.isEmpty {
                    paths += rest.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map { unquote(String($0)) }
                }
            } else if inPaths, trimmed.hasPrefix("- ") {
                paths.append(unquote(String(trimmed.dropFirst(2))))
            } else if !line.hasPrefix(" ") {
                inPaths = false
            }
        }
        return paths.filter { !$0.isEmpty }
    }

    private static func unquote(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// Every .md file under `dir`, sorted.
    static func markdownFiles(in dir: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: dir) else { return [] }
        return walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".md") }.sorted().map { "\(dir)/\($0)" }
    }

    // MARK: Memory

    /// The project's auto memory: MEMORY.md's lines next to the files in the folder. nil without a folder.
    static func memory(folder: String) -> Memory? {
        let index = "\(folder)/MEMORY.md"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        let files = names.filter { $0.hasSuffix(".md") && $0 != "MEMORY.md" }
        let texts = Dictionary(uniqueKeysWithValues: files.map { ($0, (try? String(contentsOfFile: "\(folder)/\($0)", encoding: .utf8)) ?? "") })
        return memory(folder: folder, indexText: (try? String(contentsOfFile: index, encoding: .utf8)) ?? "", files: texts)
    }

    static func memory(folder: String, indexText: String, files: [String: String]) -> Memory {
        let lines = indexText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var entries: [MemoryEntry] = []
        let link = /^\s*-\s*\[(.+?)\]\(([^)]+?\.md)\)\s*(?:[—–-]\s*(.*))?$/
        for line in lines {
            guard let match = line.firstMatch(of: link) else { continue }
            let file = String(match.2)
            entries.append(MemoryEntry(file: file, title: String(match.1), hook: match.3.map(String.init) ?? "",
                                       isIndexed: true, exists: files[file] != nil))
        }
        for (file, text) in files.sorted(by: { $0.key < $1.key }) where !entries.contains(where: { $0.file == file }) {
            entries.append(MemoryEntry(file: file, title: frontmatter("name", in: text) ?? file,
                                       hook: frontmatter("description", in: text) ?? "", isIndexed: false, exists: true))
        }
        let written = Set(files.compactMap { frontmatter("name", in: $0.value) })
        let wanted = files.values.flatMap { $0.matches(of: /\[\[([^\]]+)\]\]/).map { String($0.1) } }
        let unwritten = Array(Set(wanted).subtracting(written)).sorted()
        return Memory(folder: folder, index: "\(folder)/MEMORY.md", indexLines: indexText.isEmpty ? 0 : lines.count,
                      entries: entries, unwritten: unwritten)
    }

    private static func frontmatter(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n").prefix(15) where line.hasPrefix("\(key):") {
            return unquote(String(line.dropFirst(key.count + 1)))
        }
        return nil
    }

    /// MEMORY.md without the lines that point to `file`.
    static func removingIndexLines(of file: String, from indexText: String) -> String {
        indexText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("](\(file))") }.joined(separator: "\n")
    }

    // MARK: Hints

    /// What makes the context heavy, or the memory wrong, with the file to open.
    static func hints(_ instructions: [Instruction], memory: Memory?) -> [Hint] {
        var hints: [Hint] = []
        for item in instructions where item.loading == .always && item.tokens >= heavyInstruction {
            hints.append(Hint(text: "\(name(item.path)) is \(item.isMeasured ? "" : "≈")\(TokenFormat.short(item.tokens)) tokens, read every turn. "
                + "Sections about one part of the code can move to .claude/rules with paths:, step-by-step recipes to a skill.", path: item.path))
        }
        for item in instructions where item.loading == .always && item.path.contains("/.claude/rules/") && item.tokens >= pathlessRuleHint {
            hints.append(Hint(text: "Rule \(name(item.path)) has no paths:, so it loads in every session. If it's about some files, add paths:.",
                              path: item.path))
        }
        if let memory {
            if memory.indexLines > memoryIndexLimit {
                hints.append(Hint(text: "MEMORY.md has \(memory.indexLines) lines; Claude reads the first \(memoryIndexLimit). Merge or delete old entries.",
                                  path: memory.index))
            }
            for entry in memory.entries where !entry.exists {
                hints.append(Hint(text: "MEMORY.md lists \(entry.file), but the file is gone.", path: memory.index))
            }
            for entry in memory.entries where !entry.isIndexed {
                hints.append(Hint(text: "\(entry.file) isn't in MEMORY.md, so Claude never sees it.", path: "\(memory.folder)/\(entry.file)"))
            }
        }
        return hints
    }

    private static func name(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count >= 2 && parts.last == "CLAUDE.md" ? "\(parts[parts.count - 2])/CLAUDE.md" : String(parts.last ?? "")
    }
}

extension AppStore {
    struct SourcesSnapshot: Equatable {
        var folder: String
        var instructions: [Sources.Instruction]
        var memory: Sources.Memory?
        var hints: [Sources.Hint]
    }

    /// The session's sources, read off the main thread.
    func readSources(of session: Session) async -> SourcesSnapshot? {
        guard let id = session.id, let folder = workdir(of: session), let project = project(for: session) else { return nil }
        let home = claudeHome.deletingLastPathComponent().path // the user's home; a test's own folder in tests
        let measured = Dictionary((contextUsage[id]?.memoryFiles ?? []).map { ($0.path, $0.tokens) }) { first, _ in first }
        let loaded = Set((loadedInstructions[id] ?? []).map(\.path))
        // Auto memory is the repository's: a worktree shares its project's.
        let memoryFolder = claudeHome.appending(path: "projects/\(ClaudeImport.claudeFolderName(for: project.path))/memory").path
        return await Task.detached {
            let tracked = (GitService.output(["ls-files", "--", "*CLAUDE.md"], in: folder) ?? "")
                .split(separator: "\n").map(String.init)
            let instructions = Sources.instructions(folder: folder, home: home, tracked: tracked, measured: measured, loaded: loaded)
            let memory = Sources.memory(folder: memoryFolder)
            return SourcesSnapshot(folder: folder, instructions: instructions, memory: memory,
                                   hints: Sources.hints(instructions, memory: memory))
        }.value
    }

    /// A new rule in the project, loaded only when Claude reads the files its paths: name; opens in the editor.
    func newRule(named name: String, in folder: String) {
        let slug = ClaudeLauncher.worktreeSlug(name)
        guard !slug.isEmpty else { return }
        let path = "\(folder)/.claude/rules/\(slug).md"
        if !FileManager.default.fileExists(atPath: path) {
            let text = "---\npaths:\n  - \"src/**\"\n---\n\n# \(name)\n\nWhat Claude should do when it works on these files.\n"
            do {
                try FileManager.default.createDirectory(atPath: "\(folder)/.claude/rules", withIntermediateDirectories: true)
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            } catch { bridgeError = error.localizedDescription; return }
        }
        editor.open(path)
    }

    /// Deletes a memory entry: its file and its line in MEMORY.md.
    func deleteMemory(_ entry: Sources.MemoryEntry, in memory: Sources.Memory) {
        try? FileManager.default.removeItem(atPath: "\(memory.folder)/\(entry.file)")
        if let index = try? String(contentsOfFile: memory.index, encoding: .utf8) {
            try? Sources.removingIndexLines(of: entry.file, from: index).write(toFile: memory.index, atomically: true, encoding: .utf8)
        }
    }

    /// REMEMBER: Claude picks what from this conversation should outlast it and where it belongs; writes only after an ok.
    static let rememberPrompt = "Look through this conversation for what should outlast it: a rule, a decision, a gotcha. "
        + "For each, pick where it belongs: CLAUDE.md (every session in this project), a .claude/rules file with paths: "
        + "(only when those files are read), or your auto memory (facts about me or the project). Show me the exact text "
        + "and the file for each, and write nothing until I say ok."
}
