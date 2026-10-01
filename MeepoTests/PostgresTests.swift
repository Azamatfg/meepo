import GRDB
import WebKit
import XCTest
@testable import Meepo

final class PostgresTests: XCTestCase {
    private let owner = "postgresql://fleety:s3cr%40t@127.0.0.1:5433/admin_panel"

    func testAddressesAreSplitAndMasked() throws {
        let parts = try XCTUnwrap(Postgres.parts(of: owner))
        XCTAssertEqual(parts.password, "s3cr@t")
        XCTAssertFalse(parts.url.contains("s3cr"), "the address passed on psql's command line has no password")
        XCTAssertEqual(parts.database, "admin_panel")
        XCTAssertEqual(Postgres.masked(owner), "postgresql://fleety:***@127.0.0.1:5433/admin_panel")
        XCTAssertNil(Postgres.parts(of: "mysql://x@y/z"))
        let role = try XCTUnwrap(Postgres.roleURL(from: owner, password: "abc123"))
        XCTAssertEqual(role, "postgresql://claude_ro:abc123@127.0.0.1:5433/admin_panel")
    }

    /// Every query: password only in the environment, the transaction read only, a server-side timeout.
    func testQueriesAreReadOnlyAndKeepThePasswordOutOfArgv() {
        let seen = Box()
        let runner: Postgres.Runner = { _, args, env, _ in
            seen.args = args
            seen.env = env
            return (0, "fleety|true\n", "")
        }
        let result = Postgres.query(Postgres.whoAmISQL, url: owner, psql: "/usr/bin/true", runner: runner)
        XCTAssertEqual(try? result.get(), "fleety|true")
        XCTAssertFalse(seen.args.joined(separator: " ").contains("s3cr"))
        XCTAssertTrue(seen.args.contains("-w"), "never a password prompt")
        XCTAssertEqual(seen.env["PGPASSWORD"], "s3cr@t")
        XCTAssertTrue(seen.env["PGOPTIONS"]?.contains("default_transaction_read_only=on") == true)
        XCTAssertTrue(seen.env["PGOPTIONS"]?.contains("statement_timeout") == true)
        XCTAssertEqual(Postgres.identity(from: "fleety|true"), Postgres.Identity(user: "fleety", canWrite: true))
        XCTAssertEqual(Postgres.identity(from: "claude_ro|false"), Postgres.Identity(user: "claude_ro", canWrite: false))
    }

    /// The role reads and nothing else: no write grant anywhere, read-only by default, a timeout.
    func testRoleSQLGrantsOnlySelect() {
        let sql = Postgres.roleSQL(database: "admin_panel", password: "abc123")
        XCTAssertTrue(sql.contains("GRANT SELECT ON ALL TABLES IN SCHEMA \"public\" TO claude_ro"))
        XCTAssertTrue(sql.contains("default_transaction_read_only = on"))
        XCTAssertTrue(sql.contains("NOSUPERUSER NOCREATEDB NOCREATEROLE"))
        for write in ["INSERT", "UPDATE", "DELETE", "TRUNCATE", "ALL PRIVILEGES", "GRANT ALL"] {
            XCTAssertFalse(sql.contains(write), write)
        }
        XCTAssertTrue(Postgres.newPassword().allSatisfy { $0.isLetter || $0.isNumber }, "never needs quoting in SQL or a URL")
    }

    /// .mcp.json: Claude's server moves to the role; other servers and settings stay; none → one is added.
    func testMCPConfigSwitchesOnlyThatAddress() throws {
        let config = #"{"mcpServers":{"postgres":{"command":"npx","args":["-y","@modelcontextprotocol/server-postgres","\#(owner)"]},"github":{"command":"gh"}}}"#
        let role = "postgresql://claude_ro:abc@127.0.0.1:5433/admin_panel"
        let updated = try XCTUnwrap(Postgres.mcpConfig(config, replacing: owner, with: role)?.text)
        XCTAssertTrue(updated.contains(role) && !updated.contains("fleety") && updated.contains("\"github\""))
        let added = try XCTUnwrap(Postgres.mcpConfig(nil, replacing: nil, with: role)?.text)
        XCTAssertTrue(added.contains("server-postgres") && added.contains(role))
        XCTAssertNil(Postgres.mcpConfig("{ not json", replacing: owner, with: role), "a file meepo can't read is left alone")
    }

    func testAddressesAreFoundInMCPAndEnvFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pg-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"mcpServers":{"postgres":{"args":["\#(owner)"]}}}"#.write(to: dir.appending(path: ".mcp.json"), atomically: true, encoding: .utf8)
        try "DATABASE_URL=postgres://app:pw@db:5432/app\nOTHER=1\n".write(to: dir.appending(path: ".env.local"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Postgres.foundURLs(in: dir.path), [owner, "postgres://app:pw@db:5432/app"])
    }

    /// A table with a hundred neighbours draws the first 16; names Mermaid can't take are made safe.
    func testDiagramShowsTheTableAndAtMostSixteenNeighbours() {
        let users = Postgres.Table(name: "users", columns: [.init(name: "id", type: "bigint", pk: true)], fks: [])
        let children = (0..<100).map { index in
            Postgres.Table(name: "t\(index)", columns: [.init(name: "id", type: "bigint", pk: true), .init(name: "user_id", type: "bigint", pk: false)],
                           fks: [.init(columns: ["user_id"], table: "users")])
        }
        let text = Postgres.mermaid(around: "users", in: [users] + children)
        XCTAssertEqual(text.components(separatedBy: " {").count - 1, 1 + Postgres.neighbourLimit)
        XCTAssertTrue(text.contains("users ||--o{ t0 : \"user_id\""))
        XCTAssertEqual(Postgres.neighbours(of: "users", in: [users] + children).count, 100)
        let odd = Postgres.Table(name: "billing.invoice lines", columns: [.init(name: "id", type: "character varying(20)", pk: true)], fks: [])
        XCTAssertTrue(Postgres.mermaid(around: odd.name, in: [odd]).contains("billing_invoice_lines {"))
    }
}

private final class Box: @unchecked Sendable {
    var args: [String] = []
    var env: [String: String] = [:]
}

/// DRAW: the right tools per kind, the material in the prompt, fences stripped — and a real answer draws.
final class DiagramTests: XCTestCase {
    func testOnlyAQuestionReadsAndNothingWrites() {
        XCTAssertEqual(Diagram.tools(for: .question("x")), "Read,Grep,Glob")
        XCTAssertEqual(Diagram.tools(for: .lastAnswer), "")
        XCTAssertEqual(Diagram.tools(for: .changes), "")
        let args = ClaudeHeadless.jsonArguments(schema: Diagram.schema, tools: "Read,Grep,Glob")
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "Read,Grep,Glob")
        XCTAssertEqual(args[args.firstIndex(of: "--setting-sources")! + 1], "", "still no settings files, so no hooks")
        XCTAssertTrue(args.contains("--no-session-persistence") && !args.contains("--resume"), "never a fork of the session")
    }

    func testPromptCarriesTheMaterialAndLanguage() {
        let prompt = Diagram.prompt(.lastAnswer, material: "Сначала миграция, потом деплой.", language: "Russian")
        XCTAssertTrue(prompt.contains("Сначала миграция") && prompt.contains("in Russian") && prompt.contains("At most 15 nodes"))
        XCTAssertEqual(Diagram.cleaned("```mermaid\nflowchart LR\n  A --> B\n```"), "flowchart LR\n  A --> B")
    }
}

/// Draws `text` with the bundled Mermaid in an offscreen web view: whether an SVG came out, and Mermaid's error.
@MainActor
private func renderWithBundledMermaid(_ text: String, dark: Bool) async throws -> (drawn: Bool, error: String) {
    let page = try XCTUnwrap(MermaidView.pageURL, "Mermaid/diagram.html is in the app bundle")
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    func poll(_ js: String, tries: Int) async throws -> Bool {
        for _ in 0..<tries {
            if (try? await web.evaluateJavaScript(js)) as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
    let ready = try await poll("typeof meepoRender === 'function' && typeof mermaid === 'object'", tries: 100)
    XCTAssertTrue(ready, "the page and mermaid.min.js load from the bundle")
    _ = try? await web.evaluateJavaScript("meepoRender(\(MermaidView.literal(text)), \(dark))")
    let drawn = try await poll("document.querySelector('#out svg') !== null", tries: 50)
    let error = (try? await web.evaluateJavaScript("document.querySelector('.err')?.textContent ?? ''")) as? String ?? ""
    return (drawn, error)
}

@MainActor
final class MermaidRenderTests: XCTestCase {
    /// What `Postgres.mermaid` writes for a 40-neighbour table draws, quickly.
    func testSchemaNeighbourhoodDraws() async throws {
        let users = Postgres.Table(name: "users", columns: [.init(name: "id", type: "bigint", pk: true), .init(name: "email", type: "text", pk: false)], fks: [])
        let children = (0..<40).map { index in
            Postgres.Table(name: "orders_\(index)", columns: [.init(name: "id", type: "bigint", pk: true), .init(name: "user_id", type: "bigint", pk: false)],
                           fks: [.init(columns: ["user_id"], table: "users")])
        }
        let start = ContinuousClock.now
        let (drawn, error) = try await renderWithBundledMermaid(Postgres.mermaid(around: "users", in: [users] + children), dark: false)
        XCTAssertTrue(drawn, "no diagram: \(error)")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5), "page load plus a 17-table neighbourhood")
    }

    /// A wide table (more columns than listed), odd types and names: what `Postgres.mermaid` writes still draws.
    func testWideTableWithOddColumnsDraws() async throws {
        let columns = (0..<20).map { Postgres.Column(name: $0 == 0 ? "id" : "2nd col \($0)", type: $0 % 2 == 0 ? "character varying(20)" : "timestamp with time zone", pk: $0 == 0) }
        let wide = Postgres.Table(name: "stops", columns: columns, fks: [])
        let child = Postgres.Table(name: "stop_events", columns: [.init(name: "id", type: "bigint", pk: true), .init(name: "stop_id", type: "bigint", pk: false)],
                                   fks: [.init(columns: ["stop_id"], table: "stops")])
        let text = Postgres.mermaid(around: "stops", in: [wide, child])
        XCTAssertTrue(text.contains("and_6_more_columns"), text)
        let (drawn, error) = try await renderWithBundledMermaid(text, dark: false)
        XCTAssertTrue(drawn, "no diagram: \(error)")
    }

    /// An answer claude -p really gave (Russian labels, quotes, edge labels) draws with the bundled Mermaid.
    func testARealDrawAnswerDraws() async throws {
        let answer = "flowchart LR\n    A[\"Claude свободен?\"] -->|\"нет\"| N[\"Ничего не горит\"]\n    A -->|\"да\"| B[\"Есть незакоммиченные файлы?\"]\n    B -->|\"да\"| C[\"Последний шаг simplify?\"]\n    C -->|\"нет, simplify есть\"| S[\"Горит simplify\"]\n    C -->|\"да или нет simplify\"| D[\"ship на панели?\"]\n    D -->|\"да\"| SH[\"Горит ship\"]\n    D -->|\"нет\"| N\n    B -->|\"нет\"| E[\"Последний шаг ship?\"]\n    E -->|\"да, sync есть\"| SY[\"Горит sync\"]\n    E -->|\"иначе\"| N"
        let (drawn, error) = try await renderWithBundledMermaid(answer, dark: true)
        XCTAssertTrue(drawn, "no diagram: \(error)")
    }
}

/// A database on a server: forwarded from a local port, the address rewritten to it, no prompts, nothing to inject.
final class SSHTunnelTests: XCTestCase {
    func testTunnelArgumentsAndAddress() throws {
        let args = try XCTUnwrap(SSHTunnel.arguments(host: "eom_almaty@94.131.80.147", localPort: 55400, remoteHost: "127.0.0.1", remotePort: 58432))
        XCTAssertEqual(args.suffix(3), ["-L", "127.0.0.1:55400:127.0.0.1:58432", "eom_almaty@94.131.80.147"])
        XCTAssertTrue(args.contains("BatchMode=yes") && args.contains("ExitOnForwardFailure=yes") && args.contains("-N"))
        XCTAssertNil(SSHTunnel.arguments(host: "-oProxyCommand=x", localPort: 55400, remoteHost: "127.0.0.1", remotePort: 5432))
        XCTAssertNil(SSHTunnel.arguments(host: "prod", localPort: 55400, remoteHost: "db;reboot", remotePort: 5432))
        let through = try XCTUnwrap(SSHTunnel.throughTunnel("postgresql://mds:p%40ss@127.0.0.1:58432/mds", localPort: 55400))
        XCTAssertEqual(through.url, "postgresql://mds:p%40ss@127.0.0.1:55400/mds")
        XCTAssertEqual(through.remoteHost, "127.0.0.1")
        XCTAssertEqual(through.remotePort, 58432)
        XCTAssertEqual(SSHTunnel.throughTunnel("postgresql://u@db/app", localPort: 55401)?.remotePort, 5432, "no port: Postgres's own")
        XCTAssertTrue(SSHTunnel.ports.contains(SSHTunnel.freePort() ?? 0))
    }

    /// Prod beside dev: a project whose postgres server is a local dev database gets a second server, not a swap.
    func testServerDatabaseIsAddedBesideADevOne() throws {
        let dev = "postgresql://mds:dev@127.0.0.1:58432/mds"
        let config = #"{"mcpServers":{"postgres":{"command":"npx","args":["-y","@modelcontextprotocol/server-postgres","\#(dev)"]}}}"#
        let prod = "postgresql://claude_ro:abc@127.0.0.1:55400/mds"
        let updated = try XCTUnwrap(Postgres.mcpConfig(config, replacing: "postgresql://mds:prod@127.0.0.1:55400/mds", with: prod, name: "postgres-main")?.text)
        XCTAssertTrue(updated.contains(dev), "the dev database stays")
        XCTAssertTrue(updated.contains("\"postgres-main\"") && updated.contains(prod))
    }
}

final class FindOnServerTests: XCTestCase {
    /// A container line → who owns it, which database, where it listens; odd lines skipped; no password asked for.
    func testContainersAreFound() {
        let output = "mds-kz-postgres-1|172.18.0.2|POSTGRES_USER=mds POSTGRES_DB=mds \nold-pg||POSTGRES_USER=x \nplain|172.18.0.9|\nbad;name|172.18.0.5|\n"
        let found = Postgres.found(fromServerListing: output)
        XCTAssertEqual(found.map(\.url), ["postgresql://mds@172.18.0.2:5432/mds", "postgresql://postgres@172.18.0.9:5432/postgres"])
        XCTAssertFalse(Postgres.findOnServerCommand.contains("PASSWORD"), "only USER and DB are read on the server")
    }

    /// The SQL travels as base64 — no quote reaches the shell — and names a shell would read specially are refused.
    func testRoleCommandCannotBeInjected() throws {
        let mds = Postgres.Found(container: "mds-kz-postgres-1", user: "mds", database: "mds", ip: "172.18.0.2")
        let sql = "SELECT '$(reboot)'; -- \"quotes\""
        let command = try XCTUnwrap(Postgres.createRoleCommand(in: mds, sql: sql))
        XCTAssertFalse(command.contains("reboot") || command.contains("'"), "the SQL is only there as base64")
        XCTAssertTrue(command.hasSuffix("| base64 -d | docker exec -i mds-kz-postgres-1 psql -v ON_ERROR_STOP=1 -q -U mds -d mds"))
        XCTAssertTrue(command.contains(Data(sql.utf8).base64EncodedString()))
        XCTAssertNil(Postgres.createRoleCommand(in: Postgres.Found(container: "x;reboot", user: "mds", database: "mds", ip: "1.2.3.4"), sql: sql))
    }
}

@MainActor
final class SetUpOnServerTests: XCTestCase {
    /// The role is created over ssh; when the next step fails, Claude's .mcp.json is never touched.
    func testStopsBeforeClaudeWhenTheTunnelCantOpen() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let repo = try makeTempRepo()
        try store.addProject(at: repo)
        let projectId = store.projects[0].id!
        try store.saveServer(Server(projectId: projectId, host: "eom@main", label: "main"))
        let sent = Commands()
        store.sshRunner = { (_: String, args: [String], _: TimeInterval) in
            sent.add(args.last ?? "")
            return ServerLogs.RunResult(status: 0, output: "")
        }
        let mds = Postgres.Found(container: "mds-kz-postgres-1", user: "mds", database: "mds", ip: "172.18.0.2")
        do {
            try await store.setUpOnServer(projectId: projectId, serverId: store.servers[0].id!, found: mds)
            XCTFail("no login environment in tests: the tunnel can't open")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("tunnel"), error.localizedDescription)
        }
        XCTAssertEqual(sent.all.count, 1)
        XCTAssertTrue(sent.all[0].contains("docker exec -i mds-kz-postgres-1 psql"), "the role, made inside the container")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appending(path: ".mcp.json").path), "Claude untouched")
        XCTAssertTrue(store.databases.isEmpty)
    }
}

private final class Commands: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var all: [String] { lock.withLock { list } }
    func add(_ command: String) { lock.withLock { list.append(command) } }
}

/// Every table of a real schema drawn with the bundled Mermaid. Runs only with MEEPO_SCHEMA_JSON set to a file
/// holding `Postgres.schemaSQL`'s output (TEST_RUNNER_MEEPO_SCHEMA_JSON=… xcodebuild test).
@MainActor
final class RealSchemaRenderTests: XCTestCase {
    func testEveryTableDraws() async throws {
        let path = ProcessInfo.processInfo.environment["MEEPO_SCHEMA_JSON"]
        try XCTSkipIf(path == nil, "a real schema only on request")
        let tables = try XCTUnwrap(Postgres.tables(fromJSON: String(contentsOfFile: path!, encoding: .utf8)))
        var failed: [String] = []
        for table in tables {
            let (drawn, error) = try await renderWithBundledMermaid(Postgres.mermaid(around: table.name, in: tables), dark: true)
            if !drawn { failed.append("\(table.name): \(error)") }
        }
        XCTAssertEqual(failed, [], "\(failed.count) of \(tables.count) tables didn't draw")
    }
}


/// Production: every query asks first — the rule reaches the session, next to Guided mode's, auto mode included.
@MainActor
final class DatabaseAsksTests: XCTestCase {
    func testAskRulesReachTheSession() throws {
        func ask(_ args: [String]) throws -> [String] {
            let json = try JSONSerialization.jsonObject(with: Data(args[1].utf8)) as? [String: Any]
            return ((json?["permissions"] as? [String: Any])?["ask"] as? [String]) ?? []
        }
        XCTAssertEqual(try ask(ClaudeLauncher.sessionSettings(effort: nil, asks: ["mcp__postgres-prod"])), ["mcp__postgres-prod"])
        let both = try ask(ClaudeLauncher.sessionSettings(effort: nil, guided: true, asks: ["mcp__postgres-prod"]))
        XCTAssertTrue(both.contains("mcp__postgres-prod") && both.contains("Bash(git push:*)"), "guided's rules stay")
        XCTAssertEqual(try ask(ClaudeLauncher.sessionSettings(effort: nil)), [], "nothing asks unless told")
    }

    func testNamesAndWhoAsks() throws {
        XCTAssertEqual(Postgres.mcpName(for: "postgresql://u@127.0.0.1:5433/app", server: nil), "postgres")
        XCTAssertEqual(Postgres.mcpName(for: "postgresql://u@db.taxinet.kz:5432/app", server: nil), "postgres-db-taxinet-kz")
        XCTAssertEqual(Postgres.mcpName(for: "postgresql://u@127.0.0.1:55400/mds", server: "main"), "postgres-main")
        XCTAssertTrue(Postgres.isLocal("postgresql://u@localhost/app") && !Postgres.isLocal("postgresql://u@10.8.0.5/app"))

        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        let repo = try makeTempRepo()
        try store.addProject(at: repo)
        let projectId = store.projects[0].id!
        let prod = try store.addDatabase(projectId: projectId, url: "postgresql://claude_ro:x@db.taxinet.kz:5432/app",
                                         switchingFrom: "postgresql://owner:y@db.taxinet.kz:5432/app", asksEachQuery: true)
        XCTAssertEqual(prod.mcpName, "postgres-db-taxinet-kz")
        XCTAssertEqual(store.databaseAsks(for: projectId), ["mcp__postgres-db-taxinet-kz"])
        let mcp = try String(contentsOf: repo.appending(path: ".mcp.json"), encoding: .utf8)
        XCTAssertTrue(mcp.contains("\"postgres-db-taxinet-kz\""))
        store.setAsksEachQuery(store.databases[0], false)
        XCTAssertEqual(store.databaseAsks(for: projectId), [])
    }
}


final class MCPRemoveTests: XCTestCase {
    /// Removing a database takes only its server out of .mcp.json; the others stay.
    func testRemovesOnlyThatServer() throws {
        let config = #"{"mcpServers":{"postgres":{"args":["a"]},"postgres-prod":{"args":["b"]},"github":{"command":"gh"}}}"#
        let updated = try XCTUnwrap(Postgres.mcpConfig(config, removing: "postgres-prod"))
        XCTAssertTrue(updated.contains("\"postgres\"") && updated.contains("\"github\"") && !updated.contains("postgres-prod"))
        XCTAssertNil(Postgres.mcpConfig(config, removing: "nope"), "nothing to remove: file left alone")
    }
}
