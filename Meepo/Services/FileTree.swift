import Foundation

/// The session folder as VS Code's Explorer shows it: one level at a time, folders first, `.git` and `.DS_Store` hidden
/// (VS Code's default `files.exclude`), changed files marked with their Source Control letter.
enum FileTree {
    struct Entry: Identifiable, Equatable {
        /// Relative to the session folder.
        let path: String
        let isDirectory: Bool
        var id: String { path }
        var name: String { URL(filePath: path).lastPathComponent }
    }

    static let hidden: Set<String> = [".git", ".DS_Store"]

    /// Blocking; call off the main thread. `relative` "" is the session folder itself.
    static func list(_ relative: String, in root: String) -> [Entry] {
        let dir = relative.isEmpty ? root : "\(root)/\(relative)"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { !hidden.contains($0) }.map { name in
            var isDirectory: ObjCBool = false // follows symlinks, as VS Code does
            FileManager.default.fileExists(atPath: "\(dir)/\(name)", isDirectory: &isDirectory)
            return Entry(path: relative.isEmpty ? name : "\(relative)/\(name)", isDirectory: isDirectory.boolValue)
        }
        .sorted { a, b in
            a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// A file's own status letter; a folder gets "•" when anything inside it changed.
    static func status(of entry: Entry, changes: [GitPanel.FileChange]) -> String? {
        if !entry.isDirectory { return changes.first { $0.path == entry.path }?.status }
        return changes.contains { $0.path.hasPrefix(entry.path + "/") } ? "•" : nil
    }
}
