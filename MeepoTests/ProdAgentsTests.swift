import GRDB
import os
import XCTest
@testable import Meepo

/// Production AI agents on the user's servers (2026-11-28): alive or not, restarts, the day's errors — read-only
/// templates over ssh, as ServerLogs does; nothing else ever runs there.
@MainActor
final class ProdAgentsTests: XCTestCase {
    func testTheStatusCommandIsATemplateAroundACheckedName() {
        let command = try? XCTUnwrap(ProdAgents.statusCommand(container: "tg-assistant"))
        XCTAssertEqual(command, "docker inspect -f '{{.State.Status}}|{{.State.StartedAt}}|{{.RestartCount}}' 'tg-assistant'; echo '---'; "
                       + "docker logs --since 24h 'tg-assistant' 2>&1 | grep -iE 'error|exception|traceback|panic' | tail -n 20")
        XCTAssertNil(ProdAgents.statusCommand(container: "x; rm -rf /"), "a name the template can't quote safely")
        XCTAssertNil(ProdAgents.statusCommand(container: "-it"))
    }

    func testTheAnswerReadsAsHealth() {
        let output = "running|2026-11-27T09:12:00.123Z|3\n---\n2026-11-28 ERROR timeout calling claude\nTraceback (most recent call last):\n"
        let health = ProdAgents.health(from: output, checkedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(health.state, "running")
        XCTAssertEqual(health.restarts, 3)
        XCTAssertEqual(health.errors, ["2026-11-28 ERROR timeout calling claude", "Traceback (most recent call last):"])
        XCTAssertTrue(health.isUp)
        XCTAssertFalse(ProdAgents.health(from: "exited|2026-11-27T09:12:00Z|0\n---\n", checkedAt: .now).isUp)
        XCTAssertEqual(ProdAgents.health(from: "Error: No such object: tg-assistant\n---\n", checkedAt: .now).state, "missing")
    }

    func testAgentsAreKeptPerProjectAndCheckedOverItsServer() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let store = makeIsolatedStore(db: db)
        try store.addProject(at: try makeTempRepo())
        let projectId = store.projects[0].id!
        let server = try await db.write { db -> Server in
            var server = Server(projectId: projectId, host: "taxitech@taxitech.app")
            try server.insert(db)
            return server
        }
        store.reload() // the store reads servers with projects
        let agent = try XCTUnwrap(store.addProdAgent(name: "Группы", projectId: projectId, serverId: server.id!, container: "tg-assistant"))
        XCTAssertEqual(store.prodAgents.map(\.name), ["Группы"])

        let ran = OSAllocatedUnfairLock(initialState: [String]())
        store.sshRunner = { _, args, _ in
            ran.withLock { $0.append(args.last ?? "") }
            return ServerLogs.RunResult(status: 0, output: "running|2026-11-27T09:12:00Z|0\n---\n")
        }
        await store.checkProdAgents()
        XCTAssertEqual(store.prodAgentHealth[agent.id!]?.isUp, true)
        XCTAssertEqual(ran.withLock { $0 }, [ProdAgents.statusCommand(container: "tg-assistant")!], "only the template, nothing else")
    }
}

/// The day's numbers: a script the user approved, run inside the agent's container, printing one JSON line.
@MainActor
final class ProdAgentStatsTests: XCTestCase {
    private let script = "import json\nprint(json.dumps({\"period\": \"today\", \"dialogs\": 34, \"unanswered\": 3, \"failed\": 1, \"handoffs\": 2, \"costUSD\": 4.1}))\n"

    func testOnlyAnApprovedScriptRunsAndItCantLeaveTheContainer() throws {
        var agent = ProdAgent(projectId: 1, serverId: 1, name: "a", container: "tg-assistant")
        agent.statsRunner = "python -"
        agent.statsScript = script
        XCTAssertNil(ProdAgents.statsCommand(for: agent), "not approved yet")
        agent.statsApproved = ProdAgents.approval(of: agent)
        let command = try XCTUnwrap(ProdAgents.statsCommand(for: agent))
        let encoded = Data(script.utf8).base64EncodedString()
        XCTAssertEqual(command, "echo '\(encoded)' | base64 -d | docker exec -i 'tg-assistant' python -")
        agent.statsScript = script + "print('one more line')\n"
        XCTAssertNil(ProdAgents.statsCommand(for: agent), "changed after approval: approve again")
        agent.statsApproved = ProdAgents.approval(of: agent)
        agent.statsRunner = "sh -c 'curl example.com'"
        XCTAssertNil(ProdAgents.statsCommand(for: agent), "only the listed ways to run")
    }

    func testTheLastJSONLineIsTheDay() throws {
        let stats = try XCTUnwrap(ProdAgents.stats(from: "warning: something\n{\"period\": \"24h\", \"dialogs\": 34, \"unanswered\": 3, \"failed\": 1, \"handoffs\": 2, \"costUSD\": 4.1}\n"))
        XCTAssertEqual(stats.dialogs, 34)
        XCTAssertEqual(stats.unanswered, 3)
        XCTAssertEqual(stats.costUSD, 4.1)
        XCTAssertNil(ProdAgents.stats(from: "Traceback (most recent call last):\n  ...\nNameError"))
    }
}

/// When to tell the user about a production agent (2026-11-29): it went down, came back, or errors piled up.
final class ProdAgentAlertTests: XCTestCase {
    private func health(_ state: String, errors: Int = 0) -> ProdAgents.Health {
        ProdAgents.Health(state: state, errors: Array(repeating: "ERROR x", count: errors), checkedAt: .now)
    }

    func testOnlyChangesWorthAMessageAlert() {
        XCTAssertNil(ProdAgents.alert(name: "a", from: nil, to: health("exited")), "the first look after launch only remembers")
        XCTAssertEqual(ProdAgents.alert(name: "a", from: health("running"), to: health("exited"))?.title, "a is down")
        XCTAssertEqual(ProdAgents.alert(name: "a", from: health("exited"), to: health("running"))?.title, "a is back up")
        XCTAssertEqual(ProdAgents.alert(name: "a", from: health("running", errors: 2), to: health("running", errors: 7))?.title, "a: 5 new errors")
        XCTAssertNil(ProdAgents.alert(name: "a", from: health("running", errors: 2), to: health("running", errors: 4)), "a couple more isn't news")
        XCTAssertNil(ProdAgents.alert(name: "a", from: health("exited"), to: health("exited")), "still down: said once")
        var unreachable = health("unknown")
        unreachable.problem = "taxitech.app didn't answer."
        XCTAssertNil(ProdAgents.alert(name: "a", from: health("running"), to: unreachable), "ssh trouble isn't the agent going down")
    }
}

/// An agent whose backend reports its own day over https (alva's /bi/ai-daily), the token kept in Keychain.
final class ProdAgentBITests: XCTestCase {
    func testTheBIDayReadsAsTheDaysNumbers() throws {
        let json = Data(#"{"date":"2026-11-29","dialogs":40,"replied_dialogs":31,"escalated_dialogs":6,"cost_usd":3.27,"awaiting_now":2}"#.utf8)
        let stats = try XCTUnwrap(ProdAgents.stats(fromBI: json))
        XCTAssertEqual(stats, ProdAgents.Stats(period: "today", dialogs: 40, unanswered: 3, failed: 0, handoffs: 2, costUSD: 3.27),
                       "unanswered: run but neither replied nor handed over")
        XCTAssertNil(ProdAgents.stats(fromBI: Data(#"{"error":"invalid token"}"#.utf8)))
    }

    func testTheRequestAsksForTodayWithTheToken() throws {
        let request = try XCTUnwrap(ProdAgents.biRequest(url: "https://support.alvainfo.kz/api/v1/bi/ai-daily", token: "t0k",
                                                         day: Date(timeIntervalSince1970: 1_795_900_000)))
        XCTAssertTrue(request.url!.absoluteString.hasPrefix("https://support.alvainfo.kz/api/v1/bi/ai-daily?date=2026-"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
        XCTAssertNil(ProdAgents.biRequest(url: "http://support.alvainfo.kz/api/v1/bi/ai-daily", token: "t", day: .now), "https only: the token is a secret")
    }
}
