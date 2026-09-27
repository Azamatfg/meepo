import XCTest
@testable import Meepo

/// TOOLS → PORTS: whose a port is, what Open and Stop are offered for, and that Stop never hits the wrong program.
/// (lsof parsing: PortsTests in WorktreeTests.swift.)
final class PortGroupsTests: XCTestCase {
    func testPublishedPortsReadIPv6AndRanges() {
        XCTAssertEqual(Docker.publishedPorts("0.0.0.0:5599->5432/tcp, [::]:5599->5432/tcp"), [5599], "IPv4 and IPv6 of one port")
        XCTAssertEqual(Docker.publishedPorts(":::5432->5432/tcp"), [5432], "older Docker's IPv6")
        XCTAssertEqual(Docker.publishedPorts("127.0.0.1:8000-8002->8000-8002/tcp"), [8000, 8001, 8002])
        XCTAssertEqual(Docker.publishedPorts("127.0.0.1:5672->5672/tcp, 127.0.0.1:15672->15672/tcp"), [5672, 15672])
        XCTAssertEqual(Docker.publishedPorts("6379/tcp"), [], "exposed inside Docker only")
        XCTAssertEqual(Docker.publishedPorts("0.0.0.0:53->53/udp"), [], "not a TCP port")
        XCTAssertEqual(Docker.publishedPorts(""), [])
    }

    func testGroupsByWhoseThePortIs() {
        let home = "/Users/me"
        let vscode = "/Applications/Visual Studio Code.app/Contents/Frameworks/"
        let xcodePython = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
        let listening = [
            ListeningPort(port: 63934, pid: 623, process: "rapportd", cwd: "/", path: "/usr/libexec/rapportd"),
            ListeningPort(port: 49153, pid: 1407, process: "Code Helper", cwd: "/", path: vscode + "Code Helper.app/Contents/MacOS/Code Helper"),
            ListeningPort(port: 41530, pid: 1408, process: "Code Helper (Plugin)", cwd: "\(home)/taxinet", // opened with `code .`
                          path: vscode + "Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"),
            ListeningPort(port: 6379, pid: 2946, process: "redis-server", cwd: "/opt/homebrew/var/db/redis", path: "/opt/homebrew/opt/redis/bin/redis-server"),
            ListeningPort(port: 5433, pid: 37006, process: "com.docker.backend", cwd: "\(home)/Library/Containers/com.docker.docker/Data",
                          path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"),
            ListeningPort(port: 5599, pid: 37006, process: "com.docker.backend", cwd: "\(home)/Library/Containers/com.docker.docker/Data",
                          path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"),
            ListeningPort(port: 5037, pid: 99169, process: "adb", cwd: "\(home)/taxinet/taxiapp_mobile-main", path: nil),
            ListeningPort(port: 20003, pid: 500, process: "node", cwd: "/", path: "/usr/local/bin/node"),
            ListeningPort(port: 5173, pid: 502, process: "node", cwd: "\(home)/shop/.claude/worktrees/login", path: "/usr/local/bin/node"),
            ListeningPort(port: 8000, pid: 501, process: "python3", cwd: "\(home)/Desktop/demo", // Python runs as a bundle, not an app
                          path: "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"),
            ListeningPort(port: 8888, pid: 503, process: "Python", cwd: home, // `python3 -m http.server` in a new terminal
                          path: xcodePython),
            ListeningPort(port: 7000, pid: 631, process: "ControlCenter", cwd: "\(home)/Desktop/demo",
                          path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"),
        ]
        let containers = Docker.parseContainers("""
            {"ID":"50af9188e33e","Names":"fleety-admin-db-dev","State":"running","Ports":"127.0.0.1:5433->5432/tcp","Labels":"com.docker.compose.project.working_dir=\(home)/taxinet/admin-panel,com.docker.compose.project=admin-panel,com.docker.compose.service=admin-db-dev"}
            {"ID":"cf55ca3a9700","Names":"fleety-sqlcheck","State":"running","Ports":"0.0.0.0:5599->5432/tcp, [::]:5599->5432/tcp","Labels":""}
            {"ID":"3b1a1acb63a9","Names":"payouts_redis","State":"running","Ports":"6379/tcp","Labels":"com.docker.compose.project=taxi-kolesa"}
            """)
        let projects = [Project(id: 1, name: "taxinet", path: "\(home)/taxinet", remote: nil, color: nil),
                        Project(id: 2, name: "shop", path: "\(home)/shop", remote: nil, color: nil)]
        let sessions = [PortGroups.Session(base: 20_000, project: "shop", name: "checkout", worktree: nil),
                        PortGroups.Session(base: 20_010, project: "shop", name: "login", worktree: "\(home)/shop/.claude/worktrees/login")]
        let groups = PortGroups.groups(listening: listening, containers: containers, projects: projects, sessions: sessions, home: home)

        XCTAssertEqual(groups.map(\.title), ["shop", "taxinet", "~", "~/Desktop/demo", "Containers", "Apps and macOS"])
        func rows(_ title: String) -> [String] {
            groups.first { $0.title == title }!.rows.map { "\($0.name) \($0.ports.map(String.init).joined(separator: ",")) \($0.detail)" }
        }
        XCTAssertEqual(rows("shop"), ["node 5173 session login", "node 20003 session checkout"], "a session's port block, or its worktree")
        XCTAssertEqual(rows("taxinet"), ["adb 5037 in taxiapp_mobile-main", "fleety-admin-db-dev 5433 container · admin-db-dev"],
                       "a program started in its folder; a container of a compose project inside it")
        XCTAssertEqual(rows("~/Desktop/demo"), ["python3 8000 pid 501"])
        XCTAssertEqual(rows("~"), ["Python 8888 pid 503"], "your home folder is yours too, and Python in Xcode.app isn't Xcode")
        XCTAssertNil(PortGroups.appName(path: xcodePython, home: home))
        XCTAssertEqual(PortGroups.appName(path: "/Applications/Xcode.app/Contents/MacOS/Xcode", home: home), "Xcode")
        XCTAssertEqual(rows("Containers"), ["fleety-sqlcheck 5599 container"])
        XCTAssertEqual(rows("Apps and macOS"), ["redis-server 6379 /opt/homebrew/opt/redis/bin", "ControlCenter 7000 macOS",
                                                "Visual Studio Code 41530,49153 app", "rapportd 63934 macOS"],
                       "one line per app; an app or a part of macOS stays here even run from your folders")

        let all = groups.flatMap(\.rows)
        XCTAssertEqual(all.filter { $0.openPort != nil }.map(\.openPort), [20003], "Open only for a session's own port")
        XCTAssertFalse(groups.last!.rows.contains(where: \.canStop), "apps, macOS and Homebrew's redis are never stopped")
        XCTAssertTrue(groups.dropLast().allSatisfy { $0.rows.allSatisfy(\.canStop) })
    }

    func testStopRefusesWhenThePidNoLongerHoldsThePort() {
        XCTAssertNotNil(Ports.stopRefusal(pid: 4242, port: 3000, name: "node", listeners: [5151]), "the pid may belong to another program now")
        XCTAssertNotNil(Ports.stopRefusal(pid: 4242, port: 3000, name: "node", listeners: []))
        XCTAssertNil(Ports.stopRefusal(pid: 4242, port: 3000, name: "node", listeners: [4242]))
        XCTAssertNotNil(Ports.stopRefusal(pid: 1, port: 3000, name: "launchd", listeners: [1]))
        XCTAssertNotNil(Ports.stopRefusal(pid: getpid(), port: 3000, name: "meepo", listeners: [getpid()]))
    }

    /// A real listener this test starts itself: Stop checks the port first, then frees it.
    func testStopFreesThePortOfItsOwnProgramOnly() async throws {
        let port = Int.random(in: 46_000..<47_000)
        let nc = Process()
        nc.executableURL = URL(filePath: "/usr/bin/nc")
        nc.arguments = ["-d", "-l", "127.0.0.1", String(port)]
        nc.standardInput = FileHandle.nullDevice
        nc.standardOutput = FileHandle.nullDevice
        nc.standardError = FileHandle.nullDevice
        try nc.run()
        defer { if nc.isRunning { nc.terminate() } }
        for _ in 0..<30 where !Ports.listeners(on: port).contains(nc.processIdentifier) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(Ports.listeners(on: port), [nc.processIdentifier])

        let refused = await Ports.stop(pid: nc.processIdentifier, port: port + 1, name: "nc")
        XCTAssertEqual(refused, "nc no longer listens on \(port + 1) — nothing to stop.")
        XCTAssertTrue(nc.isRunning, "not its port: left alone")

        let stopped = await Ports.stop(pid: nc.processIdentifier, port: port, name: "nc")
        XCTAssertEqual(stopped, "Stopped nc — port \(port) is free.")
        XCTAssertFalse(nc.isRunning)
    }
}
