import Foundation

/// Moving over from an IDE (SPEC module 13): VS Code, Cursor and Windsurf share one storage format.
/// Recent folders come from `workspaceStorage/*/workspace.json`, open windows from `globalStorage/storage.json`.
enum IDEImport {
    struct IDE: Hashable {
        let name: String
        /// For `open -a`.
        let app: String
        /// Folder under ~/Library/Application Support.
        let support: String
    }

    static let ides = [IDE(name: "VS Code", app: "Visual Studio Code", support: "Code"),
                       IDE(name: "Cursor", app: "Cursor", support: "Cursor"),
                       IDE(name: "Windsurf", app: "Windsurf", support: "Windsurf")]

    struct Folder: Identifiable, Equatable {
        let path: String
        var ides: [String]
        var lastUsed: Date
        var isOpen: Bool
        var id: String { path }
    }

    /// Git repositories the IDEs opened, open windows first, then most recent; `skip` = already in Meepo.
    static func recentFolders(support: URL = defaultSupport, skip: Set<String> = []) -> [Folder] {
        var found: [String: Folder] = [:]
        for ide in ides {
            let user = support.appending(path: "\(ide.support)/User")
            let open = openFolders(storage: user.appending(path: "globalStorage/storage.json"))
            let storage = user.appending(path: "workspaceStorage")
            let dirs = (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for dir in dirs {
                guard let data = try? Data(contentsOf: dir.appending(path: "workspace.json")),
                      let folder = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["folder"] as? String,
                      let path = URL(string: folder).flatMap({ $0.isFileURL ? $0.path : nil }),
                      let root = try? GitService.repositoryRoot(of: path), !skip.contains(root) else { continue }
                let used = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                var entry = found[root] ?? Folder(path: root, ides: [], lastUsed: .distantPast, isOpen: false)
                if !entry.ides.contains(ide.name) { entry.ides.append(ide.name) }
                entry.lastUsed = max(entry.lastUsed, used)
                entry.isOpen = entry.isOpen || open.contains(path)
                found[root] = entry
            }
        }
        return found.values.sorted { ($0.isOpen ? 0 : 1, $1.lastUsed) < ($1.isOpen ? 0 : 1, $0.lastUsed) }
    }

    static var defaultSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    }

    /// Folders of the windows the IDE has open (or had open when it quit).
    static func openFolders(storage: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: storage),
              let state = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["windowsState"] as? [String: Any] else { return [] }
        let windows = [state["lastActiveWindow"]].compactMap { $0 as? [String: Any] } + ((state["openedWindows"] as? [[String: Any]]) ?? [])
        return Set(windows.compactMap { ($0["folder"] as? String).flatMap(URL.init(string:))?.path })
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
        let dir = claudeHome.appending(path: "projects/\(claudeFolderName(for: path))")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let (file, date) = files.max(by: { $0.1 < $1.1 }) else { return nil }
        return ClaudeSession(id: file.deletingPathExtension().lastPathComponent, title: title(of: file) ?? "Untitled", date: date)
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

    /// Installed IDEs, for "Open in …".
    static var installed: [IDE] {
        ides.filter { ide in
            ["/Applications", "\(NSHomeDirectory())/Applications"].contains { FileManager.default.fileExists(atPath: "\($0)/\(ide.app).app") }
        }
    }
}
