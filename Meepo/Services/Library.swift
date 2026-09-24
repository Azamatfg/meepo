import Foundation

/// Shared practices (SPEC module 11): the same command/hook/agent file copied into many projects.
/// The library is a `.claude`-like folder (default `~/.claude`, or a repo of the user's choice);
/// Meepo compares every project's copy with it and moves files only on the user's click, with backups.
enum Library {
    static let kinds = ["commands", "hooks", "agents"]

    enum State: String {
        case same           // identical to the library
        case outdated       // differs and is older: the library has the newer version
        case newer          // differs and is newer: edited in the project, maybe worth lifting
        case projectOnly    // not in the library yet
    }

    struct Copy: Identifiable {
        let project: Project
        let url: URL
        let state: State
        var id: String { url.path }
    }

    struct Item: Identifiable {
        let kind: String
        let name: String           // path inside the kind folder, e.g. "ship.md", "git/pr.md"
        let libraryURL: URL?
        let copies: [Copy]
        var id: String { "\(kind)/\(name)" }
    }

    /// A chosen folder may be a repo root holding `.claude/`, or the `.claude` folder itself.
    static func resolve(_ folder: URL) -> URL {
        let nested = folder.appending(path: ".claude")
        return FileManager.default.fileExists(atPath: nested.path) ? nested : folder
    }

    static func scan(library: URL, projects: [Project]) -> [Item] {
        var items: [String: (kind: String, name: String, library: URL?, copies: [Copy])] = [:]
        for kind in kinds {
            for (name, url) in files(in: library.appending(path: kind)) {
                items["\(kind)/\(name)"] = (kind, name, url, [])
            }
        }
        for project in projects {
            let claude = URL(filePath: project.path).appending(path: ".claude")
            guard claude.resolvingSymlinksInPath().path != library.resolvingSymlinksInPath().path else { continue }
            for kind in kinds {
                for (name, url) in files(in: claude.appending(path: kind)) {
                    let key = "\(kind)/\(name)"
                    let libraryURL = items[key]?.library
                    let copy = Copy(project: project, url: url, state: state(of: url, against: libraryURL))
                    items[key, default: (kind, name, nil, [])].copies.append(copy)
                }
            }
        }
        return items.values
            .map { Item(kind: $0.kind, name: $0.name, libraryURL: $0.library, copies: $0.copies) }
            .sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
    }

    static func state(of copy: URL, against library: URL?) -> State {
        guard let library else { return .projectOnly }
        if FileManager.default.contentsEqual(atPath: copy.path, andPath: library.path) { return .same }
        return modified(copy) > modified(library) ? .newer : .outdated
    }

    /// Library → every outdated copy. Copies edited in the project ("newer") are never touched here.
    @discardableResult
    static func updateOutdated(_ item: Item, backups: URL) throws -> Int {
        guard let source = item.libraryURL else { return 0 }
        let targets = item.copies.filter { $0.state == .outdated }
        for copy in targets { try replace(copy.url, with: source, backups: backups, label: copy.project.name) }
        return targets.count
    }

    /// One copy (outdated or newer) ← library, on explicit request.
    static func overwrite(_ copy: Copy, from item: Item, backups: URL) throws {
        guard let source = item.libraryURL else { return }
        try replace(copy.url, with: source, backups: backups, label: copy.project.name)
    }

    /// Project copy → library ("this edit is good, share it").
    static func lift(_ copy: Copy, in item: Item, library: URL, backups: URL) throws {
        let target = item.libraryURL ?? library.appending(path: "\(item.kind)/\(item.name)")
        try replace(target, with: copy.url, backups: backups, label: "library")
    }

    /// Backup, then copy keeping the source's permissions (hooks must stay executable).
    private static func replace(_ target: URL, with source: URL, backups: URL, label: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            let stamp = Int(Date.now.timeIntervalSince1970)
            let backup = backups.appending(path: "practices/\(label)/\(target.lastPathComponent)-\(stamp)-\(UUID().uuidString.prefix(4))")
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: target, to: backup)
            try fm.removeItem(at: target)
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try fm.copyItem(at: source, to: target)
    }

    /// Regular files under a folder by relative path; symlinks and symlinked folders (worktree links) are skipped.
    private static func files(in dir: URL) -> [(String, URL)] {
        // A worktree links whole folders (.claude/hooks → main checkout): its files are regular, the folder isn't.
        if (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return [] }
        guard let names = FileManager.default.enumerator(atPath: dir.path) else { return [] }
        return names.compactMap { name -> (String, URL)? in
            guard let name = name as? String, !name.hasPrefix("."), !name.contains("/.") else { return nil }
            let url = dir.appending(path: name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
            return (name, url)
        }
    }

    /// `diff -u library copy`: what a project's copy changes compared to the library (review before overwriting).
    static func diff(_ copy: Copy, against item: Item) -> String {
        guard let library = item.libraryURL else { return (try? String(contentsOf: copy.url, encoding: .utf8)) ?? "" }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/diff")
        process.arguments = ["-u", "--label", "library/\(item.name)", "--label", "\(copy.project.name)/\(item.name)",
                             library.path, copy.url.path]
        let out = Pipe()
        process.standardOutput = out
        do { try process.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

/// Docker upkeep (SPEC module 11): disk usage, leftovers per project, cleanup on confirmation.
enum Docker {
    struct Usage: Equatable { let type: String; let size: String; let reclaimable: String }
    struct Container: Equatable { let name: String; let composeProject: String?; let status: String; let size: String }

    /// `docker system df --format '{{json .}}'`, one JSON object per line.
    static func parseUsage(_ output: String) -> [Usage] {
        output.split(separator: "\n").compactMap { line in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = json["Type"] as? String else { return nil }
            return Usage(type: type, size: json["Size"] as? String ?? "", reclaimable: json["Reclaimable"] as? String ?? "")
        }
    }

    /// `docker ps -a --filter status=exited --format '{{json .}}'`; compose puts the project name in a label.
    static func parseContainers(_ output: String) -> [Container] {
        output.split(separator: "\n").compactMap { line in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = json["Names"] as? String else { return nil }
            let labels = (json["Labels"] as? String ?? "").split(separator: ",")
            let project = labels.first { $0.hasPrefix("com.docker.compose.project=") }
                .map { String($0.dropFirst("com.docker.compose.project=".count)) }
            return Container(name: name, composeProject: project, status: json["Status"] as? String ?? "", size: json["Size"] as? String ?? "")
        }
    }

    /// Compose names a project after its folder: lowercased, only [a-z0-9_-].
    static func composeName(of project: Project) -> String {
        URL(filePath: project.path).lastPathComponent.lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]", with: "", options: .regularExpression)
    }

    enum Cleanup: String, CaseIterable, Identifiable {
        case containers = "Stopped containers", images = "Dangling images", buildCache = "Build cache"
        var id: String { rawValue }
        var args: [String] {
            switch self {
            case .containers: ["container", "prune", "-f"]
            case .images: ["image", "prune", "-f"]
            case .buildCache: ["builder", "prune", "-f"]
            }
        }
    }

    /// Blocking; call off the main thread. nil when docker isn't there or not running.
    static func run(_ docker: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: docker)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
