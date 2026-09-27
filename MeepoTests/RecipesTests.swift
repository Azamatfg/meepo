import XCTest
import GRDB
@testable import Meepo

final class RecipesTests: XCTestCase {
    func testSkillKeepsStepsInOrder() {
        let steps: [Recipes.Step] = [.command("simplify"), .prompt("Run the tests\nand fix what fails"), .command("commit-push-pr")]
        let text = Recipes.skill(name: "tidy-ship", steps: steps)
        XCTAssertEqual(Automations.frontmatterValue("name", in: text), "tidy-ship")
        XCTAssertEqual(Automations.frontmatterValue("disable-model-invocation", in: text), "true")
        XCTAssertEqual(Recipes.steps(inSkill: text), [.command("simplify"), .prompt("Run the tests and fix what fails"), .command("commit-push-pr")])
    }

    func testCommandWithArgumentsIsAPrompt() {
        // "/plan the login page" is words for Claude, not a bare command name.
        XCTAssertEqual(Recipes.steps(inSkill: "1. /plan the login page"), [.prompt("/plan the login page")])
    }

    func testLoopAndSchedule() {
        XCTAssertEqual(Recipes.loopCommand(skill: "ship", minutes: 30), "/loop 30m /ship")
        XCTAssertEqual(Recipes.loopCommand(skill: "ship", minutes: 120), "/loop 2h /ship")
        let request = Recipes.scheduleRequest(steps: [.command("verify"), .prompt("open a PR")], when: "every weekday at 9am ")
        XCTAssertEqual(request, "/schedule every weekday at 9am, run these steps in order, each after the one before finishes: 1) /verify; 2) open a PR")
    }

    func testCheckRoundTripsAndLeavesOtherHooks() {
        let mine: [String: Any] = ["type": "command", "command": "~/bin/notify"]
        let settings: [String: Any] = ["model": "opus", "hooks": ["Stop": [["hooks": [mine]]], "PostToolUse": [["matcher": "Edit"]]]]
        let added = Recipes.addingCheck("npm test -- --silent", to: settings)
        XCTAssertEqual(Recipes.checks(in: added), ["npm test -- --silent"])
        XCTAssertEqual(Recipes.checks(in: Recipes.addingCheck("npm test -- --silent", to: added)).count, 1, "added once")
        let removed = Recipes.removingCheck("npm test -- --silent", from: added)
        XCTAssertTrue(NSDictionary(dictionary: removed).isEqual(to: settings), "back to exactly what the user had")
        XCTAssertNil(Recipes.removingCheck("x", from: Recipes.addingCheck("x", to: [:]))["hooks"])
    }

    /// The hook as the shell runs it: silent while nothing is uncommitted, exit 2 with the output when the
    /// check fails, 0 when it passes.
    func testCheckHookBehavesInARealRepo() throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "recipes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        XCTAssertEqual(try sh("git init -q", in: repo).status, 0)

        let failing = "echo 'it'\\''s broken'; touch ran; exit 1"
        let clean = try sh(Recipes.checkHookCommand(failing), in: repo)
        XCTAssertEqual(clean.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appending(path: "ran").path), "no changes: the check doesn't run")

        try "x".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let failed = try sh(Recipes.checkHookCommand(failing), in: repo)
        XCTAssertEqual(failed.status, 2)
        XCTAssertTrue(failed.stderr.contains("it's broken"), failed.stderr)
        XCTAssertTrue(failed.stderr.contains("This check failed: \(failing)"), failed.stderr)

        XCTAssertEqual(try sh(Recipes.checkHookCommand("true"), in: repo).status, 0)
        XCTAssertEqual(Recipes.check(inHookCommand: Recipes.checkHookCommand(failing)), failing)
        XCTAssertNil(Recipes.check(inHookCommand: "npm test"), "not meepo's")
    }

    func testSavedWorkflowsReadMeta() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "wf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
        export const meta = {
          name: 'review-changes',
          description: "Review changed files, verify each finding",
        }
        const name = 'not this one'
        """.write(to: folder.appending(path: "review.js"), atomically: true, encoding: .utf8)
        try "await agent('hi')".write(to: folder.appending(path: "bare.js"), atomically: true, encoding: .utf8)
        try "notes".write(to: folder.appending(path: "README.md"), atomically: true, encoding: .utf8)

        let found = Recipes.savedWorkflows(in: [folder, folder.appending(path: "missing")])
        XCTAssertEqual(found.map(\.name), ["bare", "review-changes"])
        XCTAssertEqual(found.last?.description, "Review changed files, verify each finding")
        XCTAssertEqual(Recipes.runRequest(found[1]), "Run the saved workflow review-changes")
    }

    private func sh(_ command: String, in folder: URL) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = folder
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitForExit()
        return (process.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

@MainActor
final class WorkflowStoreTests: XCTestCase {
    private var store: AppStore!
    private var home: URL!

    override func setUp() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        home = FileManager.default.temporaryDirectory.appending(path: "wf-store-\(UUID().uuidString)")
        store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: home.appending(path: ".claude/settings.json"), meepoHome: home.appending(path: ".meepo")),
                         usageRoot: home, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        let repo = try makeTempRepo()
        try git(["config", "core.excludesFile", "/dev/null"], in: repo)   // the user's global excludes may already ignore it
        try store.addProject(at: repo)
    }

    func testButtonIsASkillFile() throws {
        let name = try store.makeButton(named: "Tidy & Ship", steps: [.command("simplify"), .command("commit-push-pr")])
        XCTAssertEqual(name, "tidy-ship")
        XCTAssertEqual(store.skillButtons, ["tidy-ship"])
        let text = try String(contentsOf: home.appending(path: ".claude/skills/tidy-ship/SKILL.md"), encoding: .utf8)
        XCTAssertEqual(Recipes.steps(inSkill: text), [.command("simplify"), .command("commit-push-pr")])
        XCTAssertThrowsError(try store.makeButton(named: "tidy-ship", steps: [.command("verify")]), "never overwrites a skill")
        store.removeButton("tidy-ship")
        XCTAssertTrue(store.skillButtons.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/tidy-ship/SKILL.md").path),
                      "unpinning keeps the skill")
    }

    func testOlderChainBecomesASkill() throws {
        let suggestion = Noticing.Suggestion(kind: .chain(["simplify", "ship"]), count: 5)
        try store.makeButton(from: suggestion)
        XCTAssertEqual(store.skillButtons, ["simplify-ship"])
        XCTAssertTrue(store.chains.isEmpty, "noticed chains no longer go to meepo's own runner")
    }

    func testProjectCheckStaysPersonal() throws {
        let project = store.projects[0]
        try store.addCheck("swift test", in: project)
        XCTAssertEqual(store.checks(in: project), ["swift test"])
        XCTAssertEqual(store.checks(in: nil), [], "not in the settings for every project")
        XCTAssertEqual(GitService.output(["status", "--porcelain", "--untracked-files=all"], in: project.path), nil,
                       "git doesn't see the personal settings file")
        try store.addCheck("swift build", in: project)
        let exclude = (try? String(contentsOf: URL(filePath: project.path).appending(path: ".git/info/exclude"), encoding: .utf8)) ?? ""
        XCTAssertEqual(exclude.components(separatedBy: "\n").filter { $0 == ".claude/settings.local.json" }.count, 1,
                       "listed once")
        try store.removeCheck("swift test", in: project)
        XCTAssertEqual(store.checks(in: project), ["swift build"])

        try store.addCheck("npm test", in: nil)
        XCTAssertEqual(store.checks(in: nil), ["npm test"])
    }
}
