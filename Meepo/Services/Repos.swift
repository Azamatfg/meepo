import Foundation

/// The git repositories a session works in. A project folder is usually one repo; some are a plain folder
/// holding several (a platform split into services), and a session may also reach into another project
/// (`claude --add-dir`). Source Control and CI show each of them.
struct Repo: Hashable, Identifiable {
    /// The folder's name, e.g. "ocpi".
    let name: String
    let path: String
    /// Reached through "Also work in" (another project), not the session's own folder.
    var isLinked = false
    var id: String { path }
}

enum Repos {
    /// `folder` itself when it's in git; else the repos directly inside it (hidden folders and dependency
    /// folders skipped); else `folder` again — so a plain folder still offers `git init`. Blocking (git).
    static func find(in folder: String) -> [Repo] {
        let url = URL(filePath: folder)
        let own = [Repo(name: url.lastPathComponent, path: folder)]
        if GitService.isRepository(folder) { return own }
        let skip: Set = ["node_modules", "Pods", "vendor", "build", "dist", "DerivedData"]
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        let nested = children
            .filter { !skip.contains($0.lastPathComponent) }
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            // Built from `folder` as given: the listing resolves symlinks (/var → /private/var), paths must match the project's.
            .map { Repo(name: $0.lastPathComponent, path: url.appending(path: $0.lastPathComponent).path) }
        return nested.isEmpty ? own : nested
    }
}
