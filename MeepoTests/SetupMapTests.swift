import XCTest
@testable import Meepo

/// Home's map of the user's Claude Code setup: what they already use, level by level, and the next steps it points to.
final class SetupMapTests: XCTestCase {
    private func facts(_ change: (inout SetupFacts) -> Void = { _ in }) -> SetupFacts {
        var facts = SetupFacts(prompts: 65, promptsToday: 10, imagePrompts: 2, scheduled: 0, userClaudeMdLines: 70,
                               personalSkills: 4, projectsWithCheck: 1, projects: 3, mcpServers: ["figma"], outputStyle: nil,
                               interrupts: 14, permissionRequests: 60, maxParallel: 3,
                               byProject: [("alva", 0.88, 37), ("meepo", 0.12, 6)])
        change(&facts)
        return facts
    }

    func testTheMapMarksWhatIsUsed() {
        let items = Dictionary(uniqueKeysWithValues: SetupMap.levels(facts()).flatMap(\.items).map { ($0.name, $0.state) })
        XCTAssertEqual(items["CLAUDE.md about you"], .done)
        XCTAssertEqual(items["Checks after each answer"], .partly, "1 of 3 projects")
        XCTAssertEqual(items["Scheduled runs"], .missing)
        XCTAssertEqual(items["Parallel sessions"], .done)
    }

    func testStepsComeFromTheWeakestHabitsMostCostlyFirst() {
        let steps = SetupMap.steps(facts())
        XCTAssertEqual(steps.first?.title, "Allow the commands Claude keeps asking for", "60 asks on 65 prompts leads")
        XCTAssertTrue(steps.contains { $0.title.hasPrefix("Plan first") }, "14 interrupts")
        XCTAssertTrue(SetupMap.steps(facts { $0.permissionRequests = 2; $0.interrupts = 1 }).allSatisfy { !$0.title.hasPrefix("Allow") && !$0.title.hasPrefix("Plan") })
    }

    func testSummaryNamesWhereTheWorkWent() {
        XCTAssertEqual(SetupMap.summary(facts()), "65 prompts (10 today). Most went to alva (88%), 37 tasks done there.")
        XCTAssertEqual(SetupMap.summary(facts { $0.isRussian = true }), "65 запросов (сегодня 10). Больше всего — alva (88%), закрыто задач: 37.")
    }

    /// Home speaks the language the user writes their prompts in.
    func testRussianIsReadFromThePrompts() {
        let entry = { (text: String) in Noticing.Entry(display: text, date: .now, session: nil) }
        XCTAssertTrue(AppStore.writesRussian([entry("что с выкатом"), entry("fix CI"), entry("проверь логи")]))
        XCTAssertFalse(AppStore.writesRussian([entry("fix the build"), entry("why is CI red"), entry("ок")]))
        XCTAssertFalse(AppStore.writesRussian([]))
    }
}
