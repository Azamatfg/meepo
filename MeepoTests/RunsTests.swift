import XCTest
@testable import Meepo

final class RunsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private var nextId: Int64 = 0

    private func event(_ name: String, _ summary: String?, _ second: Double, session: Int64 = 1) -> HookEvent {
        nextId += 1
        return HookEvent(id: nextId, sessionId: session, name: name, summary: summary, isFailure: false,
                         createdAt: start.addingTimeInterval(second))
    }

    func testARunGoesFromTheRequestToTheRealEnd() {
        let runs = Runs.from([
            event("UserPromptExpansion", "/qa", 0), event("UserPromptSubmit", "/qa", 1),       // one request
            event("PostToolUse", "Edit: /repo/a.swift", 2), event("PostToolUse", "Bash: npm test", 3),
            event("PostToolUse", "Edit: /repo/a.swift", 4), event("PostToolUse", "Write: /repo/b.md", 5),
            event("Stop", "Waiting for 1 background task · Started the build.", 6),              // not the end
            event("Stop", "QA passed.", 9),
            event("UserPromptSubmit", "ship it", 20),
        ])
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].request, "/qa")
        XCTAssertEqual(runs[0].files, ["/repo/a.swift", "/repo/b.md"])
        XCTAssertEqual(runs[0].endedAt, start.addingTimeInterval(9))
        XCTAssertEqual(runs[0].reply, "QA passed.")
        XCTAssertFalse(runs[1].isDone, "still working")
    }

    func testSessionsDontMix() {
        let runs = Runs.from([event("UserPromptSubmit", "a", 0, session: 1), event("UserPromptSubmit", "b", 1, session: 2),
                              event("PostToolUse", "Edit: /x", 2, session: 2), event("Stop", "done", 3, session: 1)])
        XCTAssertEqual(runs.first { $0.sessionId == 1 }?.files, [])
        XCTAssertEqual(runs.first { $0.sessionId == 2 }?.files, ["/x"])
    }

    /// The shape `claude -p --json-schema` returned in a real run on 2.1.282.
    func testSummaryDecodesTheStructuredAnswer() throws {
        let json = #"{"headline":"Водитель может вернуть оплату","changes":[{"kind":"new","what":"Кнопка «Возврат»","where":"Driver app → Payment"}],"check":["Возврат больше 50 000 ₸ ждёт менеджера?"],"how_to_try":"Откройте экран оплаты"}"#
        let summary = try JSONDecoder().decode(ProductSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.changes.first?.where_, "Driver app → Payment")
        XCTAssertEqual(summary.check.count, 1)
        XCTAssertEqual(summary.howToTry, "Откройте экран оплаты")
    }

    func testTheSchemaIsValidJSON() throws {
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Runs.schema.utf8)) as? [String: Any])
        XCTAssertEqual((schema["required"] as? [String])?.sorted(), ["changes", "check", "headline", "how_to_try"])
    }
}
