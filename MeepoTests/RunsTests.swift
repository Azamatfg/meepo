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

    // MARK: Requests, not prompts (taxinet, 2026-09-27: 38 prompts, 20 of them typed)

    private static let agentMessage = """
        <agent-message from="adc829373cf80ff48">
        [Subagent hand-back] The text below is the final report of a subagent this session delegated to.
          I found 12 simplification issues in the diff.
        </agent-message>
        """
    private static func taskNotification(_ id: String) -> String {
        """
        <task-notification>
        <task-id>\(id)</task-id>
        <status>completed</status>
        <summary>Agent "Simplification review" finished</summary>
        </task-notification>
        """
    }

    /// /simplify → "Waiting for 4" → a helper's report → two finished tasks → the real Stop: one request, done.
    /// Before, each report and notification was a request of its own and cut the run short ("stopped").
    func testClaudeCodesOwnTurnsCarryTheRunOn() {
        let runs = Runs.from([
            event("UserPromptExpansion", "/simplify", 0), event("UserPromptSubmit", "/simplify", 0.4),
            event("Stop", "Waiting for 4 background tasks · Запустил четыре ревью по дифу импорта. Жду результатов.", 28),
            event("UserPromptSubmit", Self.agentMessage, 83),
            event("Stop", "Waiting for 3 background tasks · Отчёт по упрощению получен.", 85),
            event("UserPromptSubmit", Self.taskNotification("a1"), 92), event("UserPromptSubmit", Self.taskNotification("a2"), 107),
            event("PostToolUse", "Edit: /repo/import.go", 150),
            event("Stop", "Упрощение импорта графика из Excel готово, все проверки проходят.", 250),
        ])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].request, "/simplify")
        XCTAssertEqual(runs[0].outcome, .done)
        XCTAssertEqual(runs[0].files, ["/repo/import.go"])
        XCTAssertEqual(runs[0].gist, "Упрощение импорта графика из Excel готово, все проверки проходят.")
    }

    /// While background work runs, what Claude said so far is the answer; the run is still working.
    func testAWaitingStopGivesTheAnswerSoFar() {
        let runs = Runs.from([event("UserPromptSubmit", "закоммить и запушь", 0),
                              event("Stop", "Waiting for 1 background task · Коммит и push сделаны, CI ещё идёт.", 600)])
        XCTAssertEqual(runs[0].outcome, .working)
        XCTAssertEqual(runs[0].gist, "Коммит и push сделаны, CI ещё идёт.")
    }

    /// Only Claude Code's own tags are its turns: an HTML-looking request is still the user's.
    func testATagOfTheUsersOwnStaysARequest() {
        XCTAssertEqual(Runs.typed("<div> fix this"), "<div> fix this")
        XCTAssertEqual(Runs.typed("<task-list> is broken"), "<task-list> is broken")
        XCTAssertNil(Runs.typed("\n" + Self.taskNotification("x")))
        XCTAssertNil(Runs.typed(Self.agentMessage))
        let runs = Runs.from([event("UserPromptSubmit", "<div> fix this", 0), event("Stop", "Fixed.", 30)])
        XCTAssertEqual(runs.map(\.request), ["<div> fix this"])
    }

    /// A paste reads as its size, the typed words around it stay.
    func testAPasteFoldsToItsSize() {
        let prompt = "задеплоил, вот результаты после \n\n<pasted_content id=\"e1b4\">\n2023-10    30\n2023-11    15\n2023-12    15\n</pasted_content id=\"e1b4\">"
        XCTAssertEqual(Runs.typed(prompt), "задеплоил, вот результаты после \n\n[pasted 3 lines]")
        XCTAssertEqual(Runs.typed("\n\n<pasted_content id=\"a\">\nonly\n</pasted_content id=\"a\">"), "[pasted 1 line]")
    }

    /// The question is the last "?" of the last paragraph — even when a sentence follows it (the 11:44 answer).
    func testTheQuestionAnAnswerEndsOn() {
        let reply = """
            Импорт графика займа из Excel готов. Бэкенд и фронтенд собираются, все тесты зелёные.

            **Проверки:**
            - Предпросмотр считает ровно то, что потом запишется?

            Закоммитить и запушить? Миграций нет. Выкат обычный, и перед ним бэкап не нужен.
            """
        let run = Run(sessionId: 1, startedAt: start, endedAt: start + 400, request: "давай импорт графика из Excel", files: [], reply: reply)
        XCTAssertEqual(run.question, "Закоммитить и запушить?")
        XCTAssertEqual(run.outcome, .askedYou)
        XCTAssertEqual(run.gist, "Импорт графика займа из Excel готов. Бэкенд и фронтенд собираются, все тесты зелёные.")
        XCTAssertEqual(Runs.gist("## Итог\n\nИмпорт готов.\n\n- тесты зелёные"), "Импорт готов.", "a heading alone isn't the gist")
        XCTAssertNil(Runs.question("Готово.\n\nСсылка: https://x.kz/?page=1 работает."), "a ? in a link isn't a question")
        XCTAssertNil(Runs.question("Все ли готово? Да.\n\nГотово."), "only the last paragraph counts")
        XCTAssertEqual(Runs.question("Готово. **Выкатить сейчас?**"), "Выкатить сейчас?")
    }

    /// The hook can't tell Esc from a message sent while Claude worked: a request the next one cut off has
    /// no reply of its own — never "stopped".
    func testARequestTheNextOneCutOffHasNoReplyOfItsOwn() {
        let runs = Runs.from([event("UserPromptSubmit", "1. результаты на рабочем столе", 0),
                              event("UserPromptSubmit", "я не могу их сюда перенести", 31),
                              event("Stop", "Скопировал скриншоты.", 300)])
        XCTAssertEqual(runs.map(\.outcome), [.noReply, .done])
    }

    /// A reply that failed, or a session closed mid-request, ends the request there — it doesn't read "working…"
    /// and count hours for days.
    func testAFailedReplyOrAClosedSessionEndsTheRequest() {
        let runs = Runs.from([event("UserPromptSubmit", "импорт", 0), event("StopFailure", "API Error: 529 Overloaded", 40),
                              event("UserPromptSubmit", "экспорт", 100, session: 2), event("SessionEnd", "prompt_input_exit", 160, session: 2),
                              event("SessionEnd", "clear", 900)])
        XCTAssertEqual(runs.map(\.outcome), [.noReply, .noReply])
        XCTAssertEqual(runs.map { $0.worked(now: start + 99_999) }, [40, 60])
    }

    /// A finished helper reads as Claude Code's own line in the feed, dim — not "You asked".
    func testClaudeCodesOwnTurnInTheFeed() {
        let line = EventStory.line(for: event("UserPromptSubmit", Self.taskNotification("a1"), 0))
        XCTAssertEqual(line?.title, "Helper “Simplification review” finished")
        XCTAssertEqual(line?.isQuiet, true)
        let report = EventStory.line(for: event("UserPromptSubmit", Self.agentMessage, 0))
        XCTAssertEqual(report?.title, "A helper's report came in")
        let typed = EventStory.line(for: event("UserPromptSubmit", "давай <pasted_content id=\"x\">a\nb</pasted_content id=\"x\">", 0))
        XCTAssertEqual(typed?.title, "You asked: “давай [pasted 2 lines]”")
        XCTAssertEqual(typed?.isQuiet, false)
    }
}
