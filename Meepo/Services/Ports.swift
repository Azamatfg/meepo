import Darwin
import Foundation

/// A TCP port something listens on, and the folder that process runs in (to tell whose it is).
struct ListeningPort: Hashable, Identifiable, Sendable {
    var port: Int
    var pid: Int32
    var process: String
    var cwd: String?
    /// The program's file, to name apps: "Code Helper (Plugin)" lives in Visual Studio Code.app.
    var path: String?
    var id: String { "\(port)-\(pid)" }
}

/// Port ranges per session (SPEC module 5) and what is listening right now.
enum Ports {
    static let firstBase = 20_000
    static let blockSize = 10

    /// Lowest block not given to another session and with none of its ports in use.
    static func nextBase(taken: Set<Int>, listening: Set<Int>) -> Int {
        var base = firstBase
        while taken.contains(base) || (base..<base + blockSize).contains(where: listening.contains) {
            base += blockSize
        }
        return base
    }

    /// Blocking (runs lsof); call off the main thread.
    static func listening() -> [ListeningPort] {
        let listen = parseListen(lsof(["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]))
        guard !listen.isEmpty else { return [] }
        let pids = Set(listen.map(\.pid)).map(String.init).joined(separator: ",")
        let cwds = parseCwd(lsof(["-a", "-p", pids, "-d", "cwd", "-F", "pn"]))
        var seen = Set<String>()
        return listen.compactMap { entry in
            let port = ListeningPort(port: entry.port, pid: entry.pid, process: entry.command, cwd: cwds[entry.pid],
                                     path: executable(of: entry.pid))
            return seen.insert(port.id).inserted ? port : nil // IPv4 + IPv6 listeners of one process
        }
        .sorted { $0.port < $1.port }
    }

    /// `lsof -F pcn`: "p<pid>", "c<command>", then one "n<address>:<port>" per socket.
    static func parseListen(_ output: String) -> [(port: Int, pid: Int32, command: String)] {
        var result: [(Int, Int32, String)] = []
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n": if let port = value.split(separator: ":").last.flatMap({ Int($0) }) { result.append((port, pid, command)) }
            default: break
            }
        }
        return result
    }

    /// `lsof -d cwd -F pn`: "p<pid>" then "n<path>".
    static func parseCwd(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            if line.hasPrefix("n"), let current = pid { result[current] = String(line.dropFirst()) }
        }
        return result
    }

    /// proc_pidpath: the program's file; nil for a process that is gone.
    static func executable(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Blocking (runs lsof): who listens on `port` right now.
    static func listeners(on port: Int) -> [Int32] {
        parseListen(lsof(["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "pcn"])).filter { $0.port == port }.map(\.pid)
    }

    /// Stop only a program that still holds the port: a program can end and its pid go to another one.
    static func stopRefusal(pid: Int32, port: Int, name: String, listeners: [Int32]) -> String? {
        if pid <= 1 || pid == getpid() { return "meepo doesn't stop itself or macOS." }
        return listeners.contains(pid) ? nil : "\(name) no longer listens on \(port) — nothing to stop."
    }

    /// Asks one of your programs to quit (SIGTERM) and says what happened 2 seconds later. Runs lsof: call it
    /// from a detached task.
    static func stop(pid: Int32, port: Int, name: String) async -> String {
        if let refusal = stopRefusal(pid: pid, port: port, name: name, listeners: listeners(on: port)) { return refusal }
        guard kill(pid, SIGTERM) == 0 else { return "Couldn't stop \(name): \(String(cString: strerror(errno)))." }
        try? await Task.sleep(for: .seconds(2))
        let now = listeners(on: port)
        if now.isEmpty { return "Stopped \(name) — port \(port) is free." }
        if now.contains(pid) { return "\(name) is still running: it didn't quit when asked. Stop it in the terminal it runs in (Ctrl+C)." }
        return "It started again: something restarts \(name) as soon as it stops (a file watcher, pm2, brew services). Stop it where it was started."
    }

    private static func lsof(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/lsof")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitForExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// TOOLS → PORTS by whose they are: a project (a program started in its folder, its containers, a session's own
/// ports), another folder of yours, other containers, then apps and macOS — folded, and never stopped.
enum PortGroups {
    struct Row: Identifiable, Equatable {
        enum Owner: Equatable { case process(Int32), container(String) }
        let owner: Owner
        let name: String
        let detail: String
        var ports: [Int]
        /// A session's own port: Open shows it in the browser.
        var openPort: Int?
        /// Your own programs and containers; apps, macOS and meepo itself never.
        let canStop: Bool
        var id: String { "\(owner) \(name)" }
    }

    struct Group: Identifiable, Equatable {
        enum Kind: Int { case project, folder, containers, apps }
        let title: String
        let kind: Kind
        var rows: [Row]
        var id: String { "\(kind.rawValue) \(title)" }
    }

    /// A session: its ports (PORT…PORT+9) and its worktree folder, if it has one.
    struct Session {
        let base: Int?
        let project: String
        let name: String
        let worktree: String?
    }

    static let apps = "Apps and macOS"

    static func groups(listening: [ListeningPort], containers: [Docker.Container], projects: [Project],
                       sessions: [Session], home: String) -> [Group] {
        var groups: [String: Group] = [:]
        func add(_ row: Row, to title: String, _ kind: Group.Kind) {
            groups["\(kind.rawValue) \(title)", default: Group(title: title, kind: kind, rows: [])].rows.append(row)
        }
        func session(of ports: [Int]) -> (session: Session, port: Int)? {
            for port in ports {
                if let session = sessions.first(where: { $0.base.map { ($0..<$0 + Ports.blockSize).contains(port) } ?? false }) {
                    return (session, port)
                }
            }
            return nil
        }

        // Docker publishes a container's ports through its own program; the container is what they belong to.
        var published = Set<Int>()
        for container in containers where container.isRunning {
            let ports = Docker.publishedPorts(container.ports)
            guard !ports.isEmpty else { continue }
            published.formUnion(ports)
            let open = session(of: ports)
            let service = container.labels["com.docker.compose.service"]
            let row = Row(owner: .container(container.id), name: container.name, detail: "container" + (service.map { " · \($0)" } ?? ""),
                          ports: ports, openPort: open?.port, canStop: true)
            if let open {
                add(row, to: open.session.project, .project)
            } else if let project = Docker.owner(workingDir: container.workingDir, compose: container.composeProject, projects: projects) {
                add(row, to: project.name, .project)
            } else {
                add(row, to: container.composeProject ?? "Containers", .containers)
            }
        }

        for (pid, entries) in Dictionary(grouping: listening.filter { !published.contains($0.port) }, by: \.pid) {
            let first = entries[0]
            let ports = Set(entries.map(\.port)).sorted()
            let app = appName(path: first.path, home: home)
            let cwd = first.cwd ?? "/"
            // An installed app, a part of macOS or meepo itself is never yours to stop, wherever it was started from
            // (VS Code opened with `code .` runs in the project folder).
            let isOwn = app == nil && !isSystem(first.path) && pid != getpid()
            if isOwn, let open = session(of: ports) {
                add(Row(owner: .process(pid), name: first.process, detail: "session \(open.session.name)", ports: ports,
                        openPort: open.port, canStop: true), to: open.session.project, .project)
            } else if isOwn, let worktree = sessions.first(where: { $0.worktree.map { cwd == $0 || cwd.hasPrefix($0 + "/") } ?? false }) {
                add(Row(owner: .process(pid), name: first.process, detail: "session \(worktree.name)", ports: ports, canStop: true),
                    to: worktree.project, .project)
            } else if isOwn, let project = Docker.owner(workingDir: cwd, compose: nil, projects: projects) {
                let folder = cwd.count > project.path.count ? String(cwd.dropFirst(project.path.count + 1)) : ""
                add(Row(owner: .process(pid), name: first.process, detail: folder.isEmpty ? "in its folder" : "in \(folder)",
                        ports: ports, canStop: true), to: project.name, .project)
            } else if isOwn, cwd == home || cwd.hasPrefix(home + "/"), !cwd.hasPrefix(home + "/Library/") { // a new terminal starts in ~
                add(Row(owner: .process(pid), name: first.process, detail: "pid \(pid)", ports: ports, canStop: true),
                    to: "~" + cwd.dropFirst(home.count), .folder)
            } else { // and what launchd started outside your folders, like Homebrew's services: a Stop wouldn't last
                let detail = isSystem(first.path) ? "macOS" : app != nil ? "app"
                    : first.path.map { URL(filePath: $0).deletingLastPathComponent().path } ?? "pid \(pid)"
                add(Row(owner: .process(pid), name: app ?? first.process, detail: detail, ports: ports, canStop: false), to: apps, .apps)
            }
        }

        return groups.values.map { group in
            var group = group
            if group.kind == .apps { // one line per app, not per helper process
                var merged: [Row] = []
                for row in group.rows {
                    if let index = merged.firstIndex(where: { $0.name == row.name }) { merged[index].ports = (merged[index].ports + row.ports).sorted() }
                    else { merged.append(row) }
                }
                group.rows = merged
            }
            group.rows.sort { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
            return group
        }
        .sorted { ($0.kind.rawValue, $0.title.lowercased()) < ($1.kind.rawValue, $1.title.lowercased()) }
    }

    /// The installed app a program belongs to, its outermost .app: "Code Helper (Plugin)" → "Visual Studio Code".
    /// A program that merely runs as a bundle — Python's Python.app, an app built in a project — isn't one.
    static func appName(path: String?, home: String) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        // macOS's python3 runs from inside Xcode.app: `python3 manage.py runserver` is your program, not Xcode.
        if let inner = path.range(of: ".app/", options: .backwards), path[..<inner.lowerBound].hasSuffix("/Python") { return nil }
        let bundle = String(path[..<range.lowerBound])
        guard ["/Applications/", "/System/", home + "/Applications/", home + "/Library/"].contains(where: bundle.hasPrefix) else { return nil }
        return URL(filePath: bundle).lastPathComponent
    }

    /// macOS's own programs and daemons; the commands in /usr/bin (python3, ruby, nc) are what you run yourself.
    private static func isSystem(_ path: String?) -> Bool {
        guard let path else { return false }
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }
}
