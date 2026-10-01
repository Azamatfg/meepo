import Darwin
import Foundation

/// A database on a server, reached through `ssh -L`: a local port on 127.0.0.1 forwarded to where the database
/// listens as the server sees it. meepo keeps it open while it runs; the database port never has to face the internet.
enum SSHTunnel {
    /// Local ports meepo forwards from; the first free one goes to a new database.
    static let ports = 55400..<55500

    /// No prompts (keys and agent only), fails if the port can't be forwarded, notices a dead link within a minute.
    static func arguments(host: String, localPort: Int, remoteHost: String, remotePort: Int) -> [String]? {
        guard ServerLogs.isValidHost(host), (1...65535).contains(localPort), (1...65535).contains(remotePort),
              remoteHost.wholeMatch(of: /[A-Za-z0-9._-]{1,253}/) != nil else { return nil }
        return ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=20",
                "-o", "ServerAliveCountMax=3", "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)", host]
    }

    /// The first port in `ports` nothing listens on (and not in `taken`).
    static func freePort(excluding taken: Set<Int> = []) -> Int? {
        ports.first { !taken.contains($0) && isFree($0) }
    }

    static func isFree(_ port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// The database's address as the server sees it → the same address through the tunnel's local port.
    /// ("postgresql://mds:pw@127.0.0.1:58432/mds", 55400) → ("postgresql://mds:pw@127.0.0.1:55400/mds", "127.0.0.1", 58432)
    static func throughTunnel(_ url: String, localPort: Int) -> (url: String, remoteHost: String, remotePort: Int)? {
        guard var components = URLComponents(string: url), let host = components.host else { return nil }
        let remotePort = components.port ?? 5432
        components.host = "127.0.0.1"
        components.port = localPort
        return components.string.map { ($0, host, remotePort) }
    }
}
