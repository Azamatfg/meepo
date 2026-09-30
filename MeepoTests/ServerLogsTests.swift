import GRDB
import XCTest
@testable import Meepo

/// Records what would run over ssh and answers with canned output: no real ssh in tests.
private final class FakeSSH: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(executable: String, args: [String], timeout: TimeInterval)] = []
    var answer = ServerLogs.RunResult(status: 0, output: "")

    var calls: [(executable: String, args: [String], timeout: TimeInterval)] { lock.withLock { _calls } }

    var runner: ServerLogs.Runner {
        { executable, args, timeout in
            self.lock.withLock {
                self._calls.append((executable, args, timeout))
                return self.answer
            }
        }
    }
}

final class SSHConfigTests: XCTestCase {
    func testHostsWithSeveralNamesPatternsAndGitAliases() {
        let config = """
            Include ~/.orbstack/ssh/config
            Include config.d/*

            # prod box
            Host prod prod-db  "stage"
              HostName 10.0.0.5
              User deploy

            Host *.internal web-?  !bastion
              ProxyJump bastion

            Host=bastion
              HostName=bastion.example.com

            Host github-work
              HostName github.com
              IdentityFile ~/.ssh/work

            Host gitlab.com
              User git

            Host -oProxyCommand=evil
              HostName x

            Match host prod exec "true"
              HostName github.com

            Host *
              AddKeysToAgent yes
            """
        XCTAssertEqual(SSHConfig.hosts(config), ["prod", "prod-db", "stage", "bastion"],
                       "every name of a Host line; no patterns, git aliases, Include targets or option-looking names")
    }

    /// Offered like `ssh <Tab>`: history first (newest), then config, then known_hosts; no git hosts, no repeats.
    func testSuggestionsComeFromHistoryConfigAndKnownHosts() {
        let history = """
            : 1700000000:0;ssh root@1.2.3.4
            : 1700000100:0;git push
            : 1700000200:0;ssh -T git@github.com
            ssh -p 2222 deploy@box
            : 1700000300:0;ssh root@1.2.3.4
            : 1700000400:0;ssh -i key evil@x
            """
        XCTAssertEqual(SSHConfig.history(history), ["root@1.2.3.4", "ssh://deploy@box:2222"],
                       "newest first, once; -i and git hosts left out")
        let known = """
            app.medoc.kz,10.0.0.9 ssh-ed25519 AAAA
            [stage.example.com]:2200 ssh-rsa AAAA
            |1|hashed=|salt= ssh-ed25519 AAAA
            github.com ssh-ed25519 AAAA
            @cert-authority *.example.com ssh-rsa AAAA
            """
        XCTAssertEqual(SSHConfig.knownHosts(known), ["app.medoc.kz", "10.0.0.9", "ssh://stage.example.com:2200"])
        XCTAssertEqual(SSHConfig.suggestions(config: "Host prod\n  HostName 1.2.3.4\n", knownHosts: known, history: history).prefix(3),
                       ["root@1.2.3.4", "ssh://deploy@box:2222", "prod"])
        XCTAssertEqual(SSHConfig.command(for: "ssh://deploy@box:2222"), "ssh -p 2222 deploy@box")
        XCTAssertEqual(SSHConfig.command(for: "root@1.2.3.4"), "ssh root@1.2.3.4")
        XCTAssertEqual(ServerLogs.destination(from: SSHConfig.command(for: "ssh://deploy@box:2222")), "ssh://deploy@box:2222",
                       "what's shown goes back to what's kept")
    }

    /// A Match block's HostName doesn't belong to the Host block before it (it would hide "prod" as a git alias).
    func testMatchEndsTheHostBlockAndTheFirstHostNameWins() {
        XCTAssertEqual(SSHConfig.hosts("Host prod\nMatch all\nHostName github.com\n"), ["prod"])
        XCTAssertEqual(SSHConfig.hosts("Host box\nHostName 1.2.3.4\nHostName github.com\n"), ["box"])
        XCTAssertEqual(SSHConfig.hosts("Host box\nHostName github.com\nHostName 1.2.3.4\n"), [])
        XCTAssertEqual(SSHConfig.hosts(""), [])
    }
}

final class ServerLogsTemplateTests: XCTestCase {
    func testCommandsAreTheTemplatesExactly() {
        XCTAssertEqual(ServerLogs.command(for: LogSource(kind: .journal, name: "nginx.service")),
                       "journalctl -u 'nginx.service' -n 200 --no-pager")
        XCTAssertEqual(ServerLogs.command(for: LogSource(kind: .journal, name: "getty@tty1")), "journalctl -u 'getty@tty1' -n 200 --no-pager")
        XCTAssertEqual(ServerLogs.command(for: LogSource(kind: .docker, name: "app_web-1")), "docker logs --tail 200 'app_web-1'")
        XCTAssertEqual(ServerLogs.command(for: LogSource(kind: .file, name: "/var/log/nginx/error.log")),
                       "tail -n 200 '/var/log/nginx/error.log'")
        XCTAssertEqual(ServerLogs.sshArguments(host: "deploy@prod.example.com", command: "tail -n 200 '/x'"),
                       ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "deploy@prod.example.com", "tail -n 200 '/x'"])
        XCTAssertEqual(ServerLogs.listContainers, "docker ps --format '{{.Names}}'")
    }

    /// Anything that could make the server run more than the template is refused — for every kind.
    func testNamesThatCouldRunSomethingElseAreRefused() {
        let evil = ["web; rm -rf /", "$(reboot)", "`reboot`", "web && reboot", "web | sh", "a b", "web\nreboot",
                    "web'; reboot; '", "\"web\"", "web>out", "-f", "--since=x", "web\\x2d", "", "*", "web$HOME", "web\t"]
        for kind in LogSource.Kind.allCases {
            for name in evil {
                // Inside a file path "-f" is only a name ("/var/log/-f", quoted); the rest stays refused there too.
                let path = kind == .file && !["-f", ""].contains(name) ? "/var/log/" + name : name
                for candidate in Set([name, path]) {
                    XCTAssertNil(ServerLogs.command(for: LogSource(kind: kind, name: candidate)), "\(kind): \(candidate.debugDescription)")
                }
            }
        }
        XCTAssertNil(ServerLogs.command(for: LogSource(kind: .file, name: "var/log/app.log")), "a file path is absolute")
        XCTAssertNil(ServerLogs.command(for: LogSource(kind: .docker, name: "web@1")), "@ isn't in a container name")
        XCTAssertNotNil(ServerLogs.command(for: LogSource(kind: .journal, name: "web@1")), "…but is in a unit name")
    }

    func testHostCantBeAnOption() {
        for host in ["-oProxyCommand=reboot", "prod;reboot", "prod reboot", "$(x)", "`x`", "", "a@-b", "prod\n"] {
            XCTAssertFalse(ServerLogs.isValidHost(host), host.debugDescription)
            XCTAssertNil(ServerLogs.sshArguments(host: host, command: "x"))
        }
        for host in ["prod", "deploy@10.0.0.5", "my_box.example.com", "user.name@host-1"] {
            XCTAssertTrue(ServerLogs.isValidHost(host), host)
        }
    }

    /// Pasted as typed in a terminal, kept as a host ssh reads; options that would run something are refused.
    func testPastedSSHCommandBecomesTheHost() {
        XCTAssertEqual(ServerLogs.destination(from: "ssh root@1.2.3.4"), "root@1.2.3.4")
        XCTAssertEqual(ServerLogs.destination(from: "  root@1.2.3.4 "), "root@1.2.3.4")
        XCTAssertEqual(ServerLogs.destination(from: "ssh -p 2222 deploy@box"), "ssh://deploy@box:2222")
        XCTAssertEqual(ServerLogs.destination(from: "ssh -p2222 -l deploy box"), "ssh://deploy@box:2222")
        XCTAssertEqual(ServerLogs.destination(from: "prod"), "prod")
        for typed in ["ssh -i key root@x", "ssh -oProxyCommand=reboot x", "ssh root@x uptime", "ssh -p", "ssh", "ssh -p 22;reboot x"] {
            XCTAssertNil(ServerLogs.destination(from: typed), typed)
        }
        XCTAssertTrue(ServerLogs.isValidHost("ssh://deploy@box:2222"))
        XCTAssertFalse(ServerLogs.isValidHost("ssh://-oProxyCommand=x"))
        XCTAssertFalse(ServerLogs.isValidHost("box:2222"), "a port only in ssh's URI form")
    }

    func testTrimKeepsTheLastLinesWithinTheLimit() {
        let raw = (1...500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let trimmed = ServerLogs.trim(raw)
        XCTAssertTrue(trimmed.hasPrefix("… (earlier lines cut)\nline 301\n"))
        XCTAssertTrue(trimmed.hasSuffix("line 500"))
        XCTAssertEqual(trimmed.split(separator: "\n").count, 201)

        let small = ServerLogs.trim(raw, limit: 100)
        XCTAssertLessThanOrEqual(small.utf8.count, 100 + "… (earlier lines cut)\n".utf8.count)
        XCTAssertTrue(small.hasSuffix("line 500"), "the newest lines stay, not the oldest")
        XCTAssertEqual(ServerLogs.trim("a\nb\n"), "a\nb", "nothing cut, nothing said")
    }

    /// A log line can't end the paste early and type into Claude: no escape, no carriage return, no other control.
    func testTrimDropsEverythingThatCouldTypeIntoTheTerminal() {
        let raw = "\u{1B}[31mERROR\u{1B}[0m boom\r\nok\u{1B}[201~reboot\r\u{07}\u{08}\u{9B}x\tend"
        let trimmed = ServerLogs.trim(raw)
        XCTAssertEqual(trimmed, "ERROR boom\nokrebootx\tend")
        XCTAssertFalse(trimmed.unicodeScalars.contains { $0 != "\n" && $0 != "\t" && CharacterSet.controlCharacters.contains($0) })

        let paste = ServerLogs.paste([ServerLogs.Fetched(host: "prod", command: "c", log: trimmed)])
        XCTAssertTrue(paste.hasPrefix("\u{1B}[200~") && paste.hasSuffix("\u{1B}[201~"))
        XCTAssertEqual(paste.components(separatedBy: "\u{1B}").count, 3, "only the paste's own start and end")
        XCTAssertFalse(paste.contains("\r"), "never Enter: the user sends it")
    }

    func testFetchRunsOnlyTheTemplateThroughSSH() {
        let ssh = FakeSSH()
        ssh.answer = .init(status: 0, output: "boot\npanic: nil map\n")
        let fetched = ServerLogs.fetch(LogSource(kind: .docker, name: "api"), from: "prod", runner: ssh.runner)
        XCTAssertEqual(ssh.calls.count, 1)
        XCTAssertEqual(ssh.calls[0].executable, "/usr/bin/ssh")
        XCTAssertEqual(ssh.calls[0].args, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "prod", "docker logs --tail 200 'api'"])
        XCTAssertEqual(ssh.calls[0].timeout, 15)
        XCTAssertEqual(fetched, ServerLogs.Fetched(host: "prod", command: "docker logs --tail 200 'api'", log: "boot\npanic: nil map"))

        let refused = ServerLogs.fetch(LogSource(kind: .docker, name: "api;reboot"), from: "prod", runner: ssh.runner)
        XCTAssertEqual(ssh.calls.count, 1, "an invalid name never reaches ssh")
        XCTAssertNotNil(refused.error)
    }

    func testFailuresSayWhyInPlainWords() {
        let ssh = FakeSSH()
        ssh.answer = .init(status: 255, output: "deploy@prod: Permission denied (publickey).\n")
        XCTAssertTrue(ServerLogs.fetch(LogSource(kind: .file, name: "/x"), from: "prod", runner: ssh.runner).error!
            .contains("Permission denied (publickey)"))
        ssh.answer = .init(status: 143, output: "", timedOut: true)
        XCTAssertEqual(ServerLogs.fetch(LogSource(kind: .file, name: "/x"), from: "prod", runner: ssh.runner).error, "prod didn't answer in 15 s.")
        ssh.answer = .init(status: 1, output: "Unit nope.service could not be found.\n")
        XCTAssertEqual(ServerLogs.fetch(LogSource(kind: .journal, name: "nope"), from: "prod", runner: ssh.runner).error,
                       "The server answered with an error: Unit nope.service could not be found..")
    }

    func testContainersAreListedAndOddNamesDropped() {
        let ssh = FakeSSH()
        ssh.answer = .init(status: 0, output: "web\napi_1\n$(evil)\n")
        XCTAssertEqual(ServerLogs.containers(on: "prod", runner: ssh.runner), .success(["web", "api_1"]))
        XCTAssertEqual(ssh.calls[0].args.last, "docker ps --format '{{.Names}}'")
    }
}

@MainActor
final class ServerStoreTests: XCTestCase {
    private var store: AppStore!
    private var ssh: FakeSSH!

    override func setUp() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        ssh = FakeSSH()
        store.sshRunner = ssh.runner
    }

    private var projectId: Int64 { store.projects[0].id! }

    func testServersAreSavedOnlyWhenSafeAndGoWithTheirProject() throws {
        try store.saveServer(Server(projectId: projectId, host: "prod", label: "prod", sources: [LogSource(kind: .docker, name: "web")]))
        XCTAssertEqual(store.servers(of: projectId).map(\.sources), [[LogSource(kind: .docker, name: "web")]])
        XCTAssertThrowsError(try store.saveServer(Server(projectId: projectId, host: "-oProxyCommand=x")))
        XCTAssertThrowsError(try store.saveServer(Server(projectId: projectId, host: "stage", sources: [LogSource(kind: .file, name: "/x; rm")])))
        XCTAssertEqual(store.servers.count, 1)
        store.removeProject(projectId)
        XCTAssertTrue(store.servers.isEmpty)
    }

    func testLogsArePastedWithoutEnterOrStartANewSession() async throws {
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        let sessionId = store.sessions[0].id!
        var typed: [String] = []
        store.keySink = { text, _ in typed.append(text) }
        ssh.answer = .init(status: 0, output: "OOMKilled\n")
        let fetched = await store.fetchLogs([(host: "prod", source: LogSource(kind: .docker, name: "web"))])
        store.pasteLogs(fetched, into: sessionId)
        XCTAssertEqual(typed.count, 1)
        XCTAssertTrue(typed[0].contains("OOMKilled") && typed[0].hasPrefix("\u{1B}[200~") && !typed[0].hasSuffix("\r"))

        try store.investigateLogs(fetched, in: projectId)
        XCTAssertEqual(store.sessions.count, 2)
        let prompt = store.initialPrompts[store.sessions[1].id!]!
        XCTAssertTrue(prompt.hasPrefix("Investigate these logs from prod:"))
        XCTAssertTrue(prompt.contains("docker logs --tail 200 'web'") && prompt.contains("OOMKilled"))
    }

    func testFailedDeployReadsEveryServersLogsIntoANewSession() async throws {
        try store.saveServer(Server(projectId: projectId, host: "prod", sources: [LogSource(kind: .journal, name: "app"),
                                                                                LogSource(kind: .file, name: "/var/log/app.log")]))
        try store.saveServer(Server(projectId: projectId, host: "stage"))
        ssh.answer = .init(status: 0, output: "migration failed\n")
        let run = CIRun(databaseId: 7, workflowName: "Deploy", headBranch: "main", headSha: "abcdef123", status: "completed",
                        conclusion: "failure", createdAt: .now, attempt: 1, url: "https://ci/7")
        await store.investigateDeploy(run, in: store.projects[0])
        XCTAssertEqual(ssh.calls.map { $0.args.last! }, ["journalctl -u 'app' -n 200 --no-pager", "tail -n 200 '/var/log/app.log'"])
        let prompt = store.initialPrompts[store.sessions[0].id!]!
        XCTAssertTrue(prompt.hasPrefix("Deploy “Deploy” failed on main @ abcdef1 (https://ci/7).\nInvestigate these logs from prod:"))
    }
}

@MainActor
final class ServerShellTests: XCTestCase {
    private var store: AppStore!

    override func setUp() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        try store.saveServer(Server(projectId: projectId, host: "deploy@prod", label: "prod"))
    }

    private var projectId: Int64 { store.projects[0].id! }

    func testShellIsInteractiveAndHostCantBeAnOption() {
        XCTAssertEqual(ServerLogs.shellArguments(host: "deploy@prod"), ["-o", "ConnectTimeout=10", "deploy@prod"],
                       "no BatchMode: the user answers a password or a new host key in the terminal")
        XCTAssertNil(ServerLogs.shellArguments(host: "-oProxyCommand=reboot"))
        XCTAssertThrowsError(try store.openShell(on: Server(projectId: projectId, host: "-oProxyCommand=reboot")))
    }

    /// Beside: right after the selected session, not after the project's newest one, and both on screen.
    func testBesideOpensNextToTheSelectedSessionSideBySide() throws {
        store.applyPreset(.focus) // one terminal
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        let (first, second) = (store.sessions[0].id!, store.sessions[1].id!)
        store.selectedSessionId = first
        store.shellsBeside = true
        try store.openShell(on: store.servers[0])
        let shell = store.selectedSession!
        XCTAssertEqual(shell.sshHost, "deploy@prod")
        XCTAssertEqual(store.orderedSessions.map(\.id), [first, shell.id, second])
        XCTAssertEqual(store.shell.split, 2)
        XCTAssertEqual(store.visibleSessionIds, [first, shell.id!])
        XCTAssertEqual(store.tabLabel(of: shell), "\(store.projects[0].name) · ssh prod")
    }

    /// A second shell beside the same session goes right after it as well — not behind the first shell, out of view.
    func testSecondShellBesideTheSameSessionIsTheOneOnScreen() throws {
        store.applyPreset(.focus)
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        let (first, second) = (store.sessions[0].id!, store.sessions[1].id!)
        store.shellsBeside = true
        store.selectedSessionId = first
        try store.openShell(on: store.servers[0])
        let prod = store.selectedSessionId!
        try store.saveServer(Server(projectId: projectId, host: "stage"))
        store.selectedSessionId = first
        try store.openShell(on: store.servers.first { $0.host == "stage" }!)
        let stage = store.selectedSessionId!
        XCTAssertEqual(store.orderedSessions.map(\.id), [first, stage, prod, second])
        XCTAssertEqual(store.visibleSessionIds, [first, stage])
    }

    func testNewTabGoesLastAndLeavesTheLayout() throws {
        store.applyPreset(.focus)
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        store.selectedSessionId = store.sessions[0].id
        store.shellsBeside = false
        try store.openShell(on: store.servers[0])
        XCTAssertEqual(store.orderedSessions.last?.sshHost, "deploy@prod")
        XCTAssertEqual(store.shell.split, 1)
    }

    /// A server shell edits no files here: it neither sends the morning's task into a worktree nor stands in for
    /// claude when `meepo <folder>` opens the project.
    func testShellIsNotTheProjectsClaudeSession() throws {
        try store.openShell(on: store.servers[0])
        let task = try XCTUnwrap(store.addTask("fix the login", projectId: projectId))
        try store.launchMorning([task.id!])
        XCTAssertNil(store.selectedSession?.sshHost)
        XCTAssertNil(store.selectedSession?.worktreeName)

        try store.openShell(on: store.servers[0]) // selected again, and the newest of the project
        var open = URLComponents(string: "meepo://open")!
        open.queryItems = [URLQueryItem(name: "path", value: store.projects[0].path)]
        store.openFromCommandLine(open.url!)
        XCTAssertNil(store.selectedSession?.sshHost)
        XCTAssertEqual(store.sessions.count, 3, "the claude session is picked, none is added")
    }

    /// The header and tab say where the shell is, not a model.
    func testShellShowsItsHostNotAModel() throws {
        try store.saveServer(Server(projectId: projectId, host: "stage"))
        try store.openShell(on: store.servers.first { $0.host == "stage" }!)
        XCTAssertEqual(store.modelLine(of: store.selectedSession!), "ssh stage")
        XCTAssertEqual(store.displayName(of: store.selectedSession!), "stage")
    }
}

@MainActor
final class ServerShellLayoutTests: XCTestCase {
    /// Beside widens Focus to two terminals only while a shell is open; claude's tab keeps its short caption.
    func testLastShellClosingPutsTheSplitBack() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        let projectId = store.projects[0].id!
        try store.saveServer(Server(projectId: projectId, host: "prod"))
        store.applyPreset(.focus)
        try store.createSession(projectId: projectId, model: nil, prompt: nil)
        let claude = store.sessions[0]
        store.shellsBeside = true
        try store.openShell(on: store.servers[0])
        let first = store.selectedSessionId!
        store.selectedSessionId = claude.id
        try store.openShell(on: store.servers[0])
        let second = store.selectedSessionId!
        XCTAssertEqual(store.shell.split, 2)
        XCTAssertEqual(store.tabLabel(of: claude), store.projects[0].name, "shells don't count as the project's sessions")
        store.closeSession(first)
        XCTAssertEqual(store.shell.split, 2, "one shell still open")
        store.closeSession(second)
        XCTAssertEqual(store.shell.split, 1)
        XCTAssertEqual(store.shell, ShellLayout.preset(.focus), "no edit left in the preset")
    }
}
