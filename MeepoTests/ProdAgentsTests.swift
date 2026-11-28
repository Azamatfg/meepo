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
