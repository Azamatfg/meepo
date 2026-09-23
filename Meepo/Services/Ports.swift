import Foundation

/// A TCP port something listens on, and the folder that process runs in (to tell whose it is).
struct ListeningPort: Hashable, Identifiable {
    var port: Int
    var pid: Int32
    var process: String
    var cwd: String?
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
            let port = ListeningPort(port: entry.port, pid: entry.pid, process: entry.command, cwd: cwds[entry.pid])
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

    private static func lsof(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/lsof")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
