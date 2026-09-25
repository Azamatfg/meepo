import Foundation

/// Moving into Meepo (SPEC module 13, reworked 2026-09-24): every folder Claude Code has worked in — from any
/// editor or a plain terminal — read from Claude Code's own records instead of each IDE's history:
/// `~/.claude.json` (its project list) and the `cwd` in the transcripts under `~/.claude/projects`.
enum ClaudeImport {
    struct Folder: Identifiable, Equatable {
        let path: String
        var lastUsed: Date?
        let isGit: Bool
        var session: ClaudeSession?
        var id: String { path }
    }

    static var defaultHome: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude") }
    static var defaultConfig: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json") }

    /// Folders to offer, newest first; `skip` = paths already in Meepo. A git subfolder counts as its repository.
    static func folders(claudeHome: URL = defaultHome, config: URL = defaultConfig, skip: Set<String> = [],
                        home: String = NSHomeDirectory(), scratch: [String] = scratchPrefixes) -> [Folder] {
        var used: [String: Date?] = [:]
        if let data = try? Data(contentsOf: config),
           let projects = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["projects"] as? [String: Any] {
            for path in projects.keys { used[path] = used[path] ?? nil }
        }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: claudeHome.appending(path: "projects"),
                                                                includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            guard let (cwd, date) = newestCwd(in: dir) else { continue }
            used[cwd] = max(used[cwd].flatMap { $0 } ?? .distantPast, date)
        }
        var found: [String: Folder] = [:]
        for (path, date) in used {
            var isDirectory: ObjCBool = false
            guard !isTemporary(path, scratch: scratch), path != home, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let root = try? GitService.repositoryRoot(of: path)
            let folder = root ?? path
            guard !skip.contains(folder), !isTemporary(folder, scratch: scratch) else { continue }
            var entry = found[folder] ?? Folder(path: folder, lastUsed: nil, isGit: root != nil)
            if let date { entry.lastUsed = max(entry.lastUsed ?? .distantPast, date) }
            found[folder] = entry
        }
        return found.values.map { folder in
            var folder = folder
            // Only a conversation started in the project folder itself can be resumed from there.
            folder.session = latestClaudeSession(for: folder.path, claudeHome: claudeHome)
            return folder
        }
        .sorted { ($0.lastUsed ?? .distantPast, $1.path) > ($1.lastUsed ?? .distantPast, $0.path) }
    }

    static let scratchPrefixes = ["/private/", "/tmp/", "/var/", "/Volumes/"]

    /// Scratch and system folders, and worktrees (they belong to their project).
    static func isTemporary(_ path: String, scratch: [String] = scratchPrefixes) -> Bool {
        path.contains("/.claude/worktrees/") || scratch.contains { path.hasPrefix($0) }
    }

    /// The `cwd` of the newest transcript in a Claude project folder, and when it was last written.
    static func newestCwd(in dir: URL) -> (String, Date)? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (file, date) in files.prefix(5) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let head = String(decoding: (try? handle.read(upToCount: 256_000)) ?? Data(), as: UTF8.self)
            for line in head.split(separator: "\n") where line.contains("\"cwd\"") {
                if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let cwd = object["cwd"] as? String { return (cwd, date) }
            }
        }
        return nil
    }

    struct ClaudeSession: Equatable {
        let id: String
        let title: String
        let date: Date
    }

    /// Claude Code keeps a project's transcripts in ~/.claude/projects/<path, every non [A-Za-z0-9] as "-">;
    /// it replaces UTF-16 units (JavaScript), so an emoji becomes "--".
    static func claudeFolderName(for path: String) -> String {
        String(path.utf16.map { unit in
            guard let scalar = Unicode.Scalar(unit), scalar.isASCII,
                  CharacterSet.alphanumerics.contains(scalar) else { return "-" }
            return Character(scalar)
        })
    }

    /// The newest conversation in the project, to continue with `--resume`.
    static func latestClaudeSession(for path: String, claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")) -> ClaudeSession? {
        claudeSessions(for: path, limit: 1, claudeHome: claudeHome).first
    }

    /// Conversations started in this folder, newest first (what `claude --resume` lists), for NEW SESSION.
    static func claudeSessions(for path: String, limit: Int = 20,
                               claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")) -> [ClaudeSession] {
        let dir = claudeHome.appending(path: "projects/\(claudeFolderName(for: path))")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { file, date in ClaudeSession(id: file.deletingPathExtension().lastPathComponent, title: title(of: file) ?? "Untitled", date: date) }
    }

    /// Last AI or custom title near the end of the transcript, else the last prompt. Only the tail is read:
    /// transcripts grow to tens of MB.
    static func title(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        let lines = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").reversed()
        var prompt: String?
        for line in lines where line.contains("\"customTitle\"") || line.contains("\"aiTitle\"") || line.contains("\"lastPrompt\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let title = (object["customTitle"] ?? object["aiTitle"]) as? String, !title.isEmpty { return title }
            if prompt == nil, let last = object["lastPrompt"] as? String, !last.isEmpty { prompt = last }
        }
        return prompt.map { String($0.prefix(80)) }
    }
}
