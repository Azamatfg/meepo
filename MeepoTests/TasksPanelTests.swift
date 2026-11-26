import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import Meepo

@MainActor
final class TasksPanelTests: XCTestCase {
    private let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12))!

    private func task(_ id: Int64, _ text: String, createdMinutesAgo: Double, doneMinutesAgo: Double? = nil) -> TaskItem {
        var task = TaskItem(projectId: nil, text: text)
        task.id = id
        task.createdAt = noon.addingTimeInterval(-createdMinutesAgo * 60)
        task.isDone = doneMinutesAgo != nil
        task.doneAt = doneMinutesAgo.map { noon.addingTimeInterval(-$0 * 60) }
        return task
    }

    func testDoneTasksLeaveTheOpenListAndTheLatestDoneComesFirst() {
        let board = TaskBoard([task(1, "old open", createdMinutesAgo: 300), task(2, "done first", createdMinutesAgo: 200, doneMinutesAgo: 60),
                               task(3, "done last", createdMinutesAgo: 100, doneMinutesAgo: 5), task(4, "new open", createdMinutesAgo: 10)], now: noon)
        XCTAssertEqual(board.open.map(\.text), ["old open", "new open"])
        // By when they were done, not by when they were written: the one just ticked sits right under the open ones.
        XCTAssertEqual(board.doneToday.map(\.text), ["done last", "done first"])
    }

    func testATaskJustTickedStaysInPlaceUntilItStopsLingering() {
        let tasks = [task(1, "first", createdMinutesAgo: 30), task(2, "ticked", createdMinutesAgo: 20, doneMinutesAgo: 0),
                     task(3, "third", createdMinutesAgo: 10)]
        let lingering = TaskBoard(tasks, lingering: [2], now: noon)
        XCTAssertEqual(lingering.open.map(\.text), ["first", "ticked", "third"], "between its neighbours, not at the end")
        XCTAssertEqual(lingering.doneToday, [])
        // Counted as done at once: the bar moves with the click, not with the slide.
        XCTAssertEqual([lingering.doneCount, lingering.totalCount], [1, 3])
        let settled = TaskBoard(tasks, now: noon)
        XCTAssertEqual(settled.open.map(\.text), ["first", "third"])
        XCTAssertEqual(settled.doneToday.map(\.text), ["ticked"])
        XCTAssertEqual([settled.doneCount, settled.totalCount], [1, 3], "the same numbers before and after the slide")
    }

    func testYesterdaysDoneTasksLeaveTheTasksTabAndTodaysCount() {
        let board = TaskBoard([task(1, "open", createdMinutesAgo: 3000), task(2, "today", createdMinutesAgo: 3000, doneMinutesAgo: 11 * 60),
                               task(3, "yesterday", createdMinutesAgo: 3000, doneMinutesAgo: 13 * 60)], now: noon)
        XCTAssertEqual(board.doneToday.map(\.text), ["today"])
        XCTAssertEqual(board.open.map(\.text), ["open"], "yesterday's work is in the Done tab, not here")
        XCTAssertEqual([board.doneCount, board.totalCount], [1, 2])
    }

    private func open(_ id: Int64, _ status: TaskStatus, createdMinutesAgo: Double) -> TaskItem {
        var item = task(id, "\(status.rawValue) \(id)", createdMinutesAgo: createdMinutesAgo)
        item.status = status
        return item
    }

    func testTheListShowsOnlyActiveTasksAndTheRestHaveTheirOwnPlace() {
        let board = TaskBoard([open(1, .active, createdMinutesAgo: 50), open(2, .inbox, createdMinutesAgo: 40), open(3, .inbox, createdMinutesAgo: 30),
                               open(4, .later, createdMinutesAgo: 20), open(5, .waiting, createdMinutesAgo: 10)], now: noon)
        XCTAssertEqual(board.open.map(\.text), ["active 1"])
        XCTAssertEqual(board.inbox.map(\.text), ["inbox 3", "inbox 2"], "the latest finding on top")
        XCTAssertEqual(board.later.map(\.text), ["later 4"])
        XCTAssertEqual(board.waiting.map(\.text), ["waiting 5"])
        XCTAssertEqual(board.totalCount, 1, "today's bar counts the list, not the inbox")
    }

    func testADoneTaskLeavesItsGroupWhateverItsStatus() {
        var found = open(1, .inbox, createdMinutesAgo: 30)
        found.isDone = true
        found.doneAt = noon
        let board = TaskBoard([found], now: noon)
        XCTAssertEqual([board.inbox, board.open], [[], []])
        XCTAssertEqual(board.doneToday.map(\.id), [1], "closed straight from the inbox by an agent: still today's work")
    }

    func testMoreThanFiveActiveTasksSuggestsLater() {
        let five = (1...5).map { open(Int64($0), .active, createdMinutesAgo: Double($0)) }
        XCTAssertFalse(TaskBoard(five, now: noon).isCrowded)
        XCTAssertTrue(TaskBoard(five + [open(6, .active, createdMinutesAgo: 6)], now: noon).isCrowded)
        var ticked = five + [open(6, .active, createdMinutesAgo: 6)]
        ticked[0].isDone = true
        XCTAssertFalse(TaskBoard(ticked, lingering: [1], now: noon).isCrowded, "a task just ticked is no longer in progress")
    }

    func testOldOpenTasksStayInTheListAndAnAgentsInsertGoesToTheInbox() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "status-\(UUID().uuidString).sqlite").path
        let db = try DatabaseQueue(path: file)
        try AppDatabase.migrator.migrate(db, upTo: "v23-replay-base-url")
        try db.write { try $0.execute(sql: "INSERT INTO task (text, note, attachments, isDone, createdAt) VALUES ('old', '', '[]', 0, ?)", arguments: [Date.now]) }
        try AppDatabase.migrator.migrate(db)
        // What a Claude session runs to note a finding: it knows nothing of `status`.
        let claude = try DatabaseQueue(path: file)
        try claude.write { try $0.execute(sql: "INSERT INTO task (text, note, attachments, isDone, createdAt) VALUES ('found', '', '[]', 0, ?)", arguments: [Date.now]) }
        let statuses = try db.read { try TaskItem.fetchAll($0) }.map { "\($0.text) \($0.status.rawValue)" }
        XCTAssertEqual(statuses, ["old active", "found inbox"])
    }

    func testTasksTypedInMeepoGoStraightToTheListAndMoveBetweenStatuses() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "status-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-status-\(UUID().uuidString)")!)
        let typed = try XCTUnwrap(store.addTask("typed", projectId: nil))
        XCTAssertEqual(typed.status, .active)
        for status in [TaskStatus.later, .waiting, .inbox, .active] {
            store.setStatus(try XCTUnwrap(store.tasks.first), status)
            XCTAssertEqual(try db.read { try TaskItem.fetchOne($0) }?.status, status)
        }
        XCTAssertEqual(store.tasks.first?.isDone, false, "moving doesn't close it")
    }

    private func doneDaysAgo(_ id: Int64, _ days: Int, hour: Int = 10, createdDaysAgo: Int? = nil) -> TaskItem {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: noon))!
        var task = TaskItem(projectId: nil, text: "t\(id)")
        task.id = id
        task.createdAt = calendar.date(byAdding: .day, value: -(createdDaysAgo ?? days), to: calendar.startOfDay(for: noon))!
        task.isDone = true
        task.doneAt = calendar.date(byAdding: .hour, value: hour, to: day)
        return task
    }

    func testTodayCountsSinceMidnightAndTheWeekIsTodayPlusSixDays() {
        let stats = DoneStats([doneDaysAgo(1, 0), doneDaysAgo(2, 0, hour: 0), doneDaysAgo(3, 1, hour: 23),
                               doneDaysAgo(4, 6), doneDaysAgo(5, 7), task(6, "open", createdMinutesAgo: 10)], now: noon)
        XCTAssertEqual(stats.today, 2, "last night at 23:00 is yesterday")
        XCTAssertEqual(stats.week, 4, "6 days ago is in, 7 days ago is out")
    }

    func testTheStreakCountsDaysInARowAndStopsAtAGap() {
        // Today, yesterday, the day before; then a gap; older days don't count.
        let stats = DoneStats([0, 1, 2, 4, 5].map { doneDaysAgo(Int64($0 + 1), $0) }, now: noon)
        XCTAssertEqual(stats.streak, 3)
    }

    func testTheStreakHoldsInTheMorningBeforeAnythingIsClosed() {
        let stats = DoneStats([doneDaysAgo(1, 1), doneDaysAgo(2, 2)], now: noon)
        XCTAssertEqual([stats.today, stats.streak], [0, 2], "nothing closed yet today doesn't break yesterday's streak")
        XCTAssertEqual(DoneStats([doneDaysAgo(1, 2)], now: noon).streak, 0, "a whole day without a task does")
        XCTAssertEqual(DoneStats([], now: noon).streak, 0)
    }

    func testTheChartPutsClosedAgainstAddedPerDayOldestFirst() {
        // Two found today (one already closed), one closed today that was added two days ago.
        let stats = DoneStats([doneDaysAgo(1, 0), doneDaysAgo(2, 0, createdDaysAgo: 2), task(3, "found", createdMinutesAgo: 5)], now: noon)
        XCTAssertEqual(stats.days.count, 7)
        XCTAssertEqual(stats.days.last?.date, Calendar.current.startOfDay(for: noon))
        XCTAssertEqual(stats.days.map(\.closed), [0, 0, 0, 0, 0, 0, 2])
        XCTAssertEqual(stats.days.map(\.added), [0, 0, 0, 0, 1, 0, 2], "a task counts as added on the day it was written")
    }

    func testTheFeedGroupsByDayTheLatestFirst() {
        let stats = DoneStats([doneDaysAgo(1, 2), doneDaysAgo(2, 0, hour: 9), doneDaysAgo(3, 0, hour: 11), task(4, "open", createdMinutesAgo: 1)],
                              now: noon)
        XCTAssertEqual(stats.feed.map { $0.tasks.map(\.text) }, [["t3", "t2"], ["t1"]])
    }

    func testTheOutcomeIsTheNotesLastLine() {
        var task = TaskItem(projectId: nil, text: "deploy")
        XCTAssertNil(task.outcome)
        task.note = "context from the morning\n\nDone: PR #753 merged, deployed 14:10\n  "
        XCTAssertEqual(task.outcome, "Done: PR #753 merged, deployed 14:10")
    }

    /// Claude closes a task with `sqlite3` while Meepo runs: the panel picks it up without a restart.
    func testATaskClosedByAnotherProcessShowsUp() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "tasks-\(UUID().uuidString).sqlite").path
        let db = try DatabaseQueue(path: file)
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "tasks-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-tasks-\(UUID().uuidString)")!)
        let task = try XCTUnwrap(store.addTask("ship it", projectId: nil))
        store.reloadTasksIfChangedOutside()

        let claude = try DatabaseQueue(path: file)
        try claude.write { try $0.execute(sql: "UPDATE task SET isDone = 1, doneAt = ? WHERE id = ?", arguments: [Date.now, task.id]) }
        XCTAssertEqual(store.tasks.first?.isDone, false, "not seen before the next look")
        store.reloadTasksIfChangedOutside()
        XCTAssertEqual(store.tasks.first?.isDone, true)
        XCTAssertEqual(DoneStats(store.tasks).today, 1)
    }

    /// Pictures of the Tasks panel, both tabs, for looking at by eye. Runs only with MEEPO_SNAPSHOT_DIR set.
    func testPictures() async throws {
        let path = ProcessInfo.processInfo.environment["MEEPO_SNAPSHOT_DIR"]
        try XCTSkipIf(path == nil, "pictures only on request")
        let dir = URL(fileURLWithPath: path!)
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "snapt-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-snap-\(UUID().uuidString)")!)
        for name in ["alva", "meepo"] {
            let repo = FileManager.default.temporaryDirectory.appending(path: "snapt-\(UUID().uuidString)/\(name)")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try store.addProject(at: repo)
        }
        let (alva, meepo) = (store.projects[0].id, store.projects[1].id)
        store.addTask("Refunds for Kaspi payments: the button on a paid trip and the ledger entry behind it", projectId: alva)
        store.addTask("Driver payouts: retry a failed transfer once", projectId: alva)
        store.addTask("Write the release notes", projectId: meepo)
        for (text, status) in [("Onboarding copy", TaskStatus.active), ("Update the README", .active), ("Rotate the API key", .active),
                               ("Fleety: phones for 29 employees without one", .waiting), ("Dark mode for the widget", .later)] {
            store.setStatus(try XCTUnwrap(store.addTask(text, projectId: meepo)), status)
        }
        // A week of work: some closed each day, some found.
        let calendar = Calendar.current
        for (daysAgo, closed, added) in [(6, 3, 4), (5, 5, 2), (4, 0, 1), (3, 4, 6), (2, 6, 5), (1, 8, 9), (0, 4, 3)] {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now))!
            for n in 0..<max(closed, added) {
                var task = try XCTUnwrap(store.addTask(["Fix the 10-second stall", "Stack traces in lag.log", "Payout retry for Kaspi",
                                                        "Socket reconnect after background"][n % 4], projectId: n % 2 == 0 ? meepo : alva))
                task.createdAt = n < added ? day.addingTimeInterval(9 * 3600) : day.addingTimeInterval(-86400 * 10)
                if n < closed {
                    task.isDone = true
                    task.doneAt = min(.now, day.addingTimeInterval(Double(10 + n) * 3600))
                    if n == 0 { task.note = "Done: PR #75\(n + daysAgo) merged, deployed" }
                }
                let row = task
                try await db.write { try row.update($0) }
            }
        }
        for (text, project) in [("ALVA: the charging socket doesn't reconnect after the app comes back from background (iOS #28)", alva),
                                ("LogoutAll closes sessions Redis first, then the DB — a login in between survives", meepo)] {
            store.setStatus(try XCTUnwrap(store.addTask(text, projectId: project)), .inbox)
        }
        store.reloadTasks()

        let defaults = UserDefaults.standard
        let savedTab = defaults.string(forKey: "tasksTab")
        defer { defaults.set(savedTab, forKey: "tasksTab") }
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 340, height: 760), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ScrollView { TasksPanel().padding(10) }
            .frame(width: 320, height: 740)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(10).background(Tokens.ground).environment(store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for tab in [TasksPanel.Tab.tasks, .inbox, .done] {
            defaults.set(tab.rawValue, forKey: "tasksTab")
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(700))
                let view = try XCTUnwrap(window.contentView)
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(tab.rawValue)-\(theme).png"))
            }
        }
    }
}
