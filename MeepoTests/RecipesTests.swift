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

    /// Checks as people type them — a trailing `;`, a background `&`, a `# comment` — still run as the shell
    /// sees them, instead of the hook failing to parse (which would block Claude after every answer).
    func testChecksWithShellEndingsStillParse() throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "recipes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        XCTAssertEqual(try sh("git init -q && echo x > a.txt", in: repo).status, 0)
        for check in ["true;", "true # fast", "true &"] {
            XCTAssertEqual(try sh(Recipes.checkHookCommand(check), in: repo).status, 0, check)
            XCTAssertEqual(Recipes.check(inHookCommand: Recipes.checkHookCommand(check)), check)
        }
        XCTAssertEqual(try sh(Recipes.checkHookCommand("false # always"), in: repo).status, 2)
    }

    func testDescriptionIsAQuotedYAMLString() throws {
        let text = Recipes.skill(name: "lint", steps: [.prompt("Fix lint: run npm test # all of it")])
        let line = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("description: ") })
        let value = String(line.dropFirst("description: ".count))
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(value.utf8)), "Runs Fix lint: run npm test # all of it")
    }

    /// "New command…": Claude may start it (no disable-model-invocation), or a workflow using it as a step would
    /// stop at "cannot be used with Skill tool due to disable-model-invocation".
    func testNewCommandIsOneClaudeCanStart() {
        let text = Recipes.command(name: "check-staging", instructions: "  Open staging and check the login.\nTell me what broke.\n")
        XCTAssertNil(Automations.frontmatterValue("disable-model-invocation", in: text))
        XCTAssertEqual(Automations.frontmatterValue("name", in: text), "check-staging")
        XCTAssertEqual(CommandCatalog.description(in: text), "Open staging and check the login.")
        XCTAssertTrue(text.hasSuffix("Open staging and check the login.\nTell me what broke.\n"))
    }

    func testNameProblems() {
        XCTAssertNotNil(Recipes.nameProblem("", taken: []))
        XCTAssertNotNil(Recipes.nameProblem("clear", taken: []), "Claude Code's own")
        XCTAssertNotNil(Recipes.nameProblem("plan", taken: []))
        XCTAssertNotNil(Recipes.nameProblem("sync", taken: ["sync"]), "a project's /sync would be replaced by yours")
        XCTAssertNil(Recipes.nameProblem("check-staging", taken: ["sync"]))
    }

    /// Steps are what Claude can start: not Claude Code's /plan (a screen), not "only you" commands, not meepo's
    /// buttons — but a project's own plan.md is a command like any other.
    func testStepChoicesAreWhatClaudeCanRun() throws {
        let project = FileManager.default.temporaryDirectory.appending(path: "steps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: project) }
        let builtInOnly = CommandCatalog.commands(projectPath: project.path, home: project)
        XCTAssertFalse(Recipes.stepChoices(builtInOnly, buttons: [], overrides: [:]).map(\.name).contains("plan"))
        XCTAssertTrue(Recipes.stepChoices(builtInOnly, buttons: [], overrides: [:]).map(\.name).contains("simplify"))

        func write(_ path: String, _ text: String) throws {
            let url = project.appending(path: ".claude/\(path)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("commands/plan.md", "Plan it our way")
        try write("skills/deploy/SKILL.md", "---\nname: deploy\ndisable-model-invocation: true\n---\nDeploy.")
        try write("skills/tidy-ship/SKILL.md", Recipes.skill(name: "tidy-ship", steps: [.command("simplify")]))
        try write("commands/review-copy.md", "Review the copy")
        try write("commands/old-deploy.md", "Deploy the old way")
        try write("commands/qa.md", "Check it in the browser")
        let names = Recipes.stepChoices(CommandCatalog.commands(projectPath: project.path, home: project), buttons: ["tidy-ship"],
                                        overrides: ["review-copy": "user-invocable-only", "old-deploy": "off", "qa": "name-only"]).map(\.name)
        XCTAssertTrue(names.contains("plan"), "the project's own /plan is a command Claude can run")
        XCTAssertFalse(names.contains("deploy"), "only you, set in its file")
        XCTAssertFalse(names.contains("tidy-ship"), "meepo's button")
        XCTAssertFalse(names.contains("review-copy"), "only you, set in your settings")
        XCTAssertFalse(names.contains("old-deploy"), "switched off in your settings: neither you nor Claude runs it")
        XCTAssertTrue(names.contains("qa"), "name-only: listed without its description, Claude still runs it")
    }

    func testChainAndCanRun() {
        XCTAssertEqual(Recipes.chain(of: [.command("simplify"), .command("sync")]), ["simplify", "sync"])
        XCTAssertNil(Recipes.chain(of: [.command("simplify"), .command("sync"), .prompt("run the tests")]))
        XCTAssertNil(Recipes.chain(of: [.command("simplify")]))
        XCTAssertTrue(Recipes.canRun([.command("simplify"), .prompt("x")], with: ["simplify"]))
        XCTAssertFalse(Recipes.canRun([.command("simplify"), .command("sync")], with: ["simplify"]))
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
    }

    func testNewCommandIsAPersonalSkillAndAStep() throws {
        let name = try store.makeCommand(named: "Check Staging", instructions: "Open staging, check the login, tell me what broke.")
        XCTAssertEqual(name, "check-staging")
        let file = home.appending(path: ".claude/skills/check-staging/SKILL.md")
        XCTAssertNil(Automations.frontmatterValue("disable-model-invocation", in: try String(contentsOf: file, encoding: .utf8)))
        XCTAssertEqual(ChangeLog.entries(backups: store.backupsDir).map(\.action), ["New skill /check-staging"], "undo in Tools → Changes")
        let commands = try XCTUnwrap(store.commandsByProject[store.projects[0].id!])
        XCTAssertTrue(Recipes.stepChoices(commands, buttons: store.skillButtons, overrides: [:]).contains { $0.name == "check-staging" },
                      "a step right away")
    }

    func testTakenOrClaudeCodesNameIsRefused() throws {
        XCTAssertThrowsError(try store.makeCommand(named: "clear", instructions: "x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/clear").path))
        let own = URL(filePath: store.projects[0].path).appending(path: ".claude/commands/deploy.md")
        try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Deploy the app".write(to: own, atomically: true, encoding: .utf8)
        store.refreshProjects()
        XCTAssertThrowsError(try store.makeCommand(named: "deploy", instructions: "x"), "yours would replace the project's /deploy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/deploy").path))
    }

    /// A /simplify → /sync button has nothing to do in a project without /sync: it isn't shown there.
    func testButtonHiddenWhereAStepIsMissing() throws {
        let project = store.projects[0]
        try store.makeButton(named: "simplify-sync", steps: [.command("simplify"), .command("sync")])
        XCTAssertEqual(store.skillButtons(for: project.id!), [])
        let sync = URL(filePath: project.path).appending(path: ".claude/commands/sync.md")
        try FileManager.default.createDirectory(at: sync.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Sync".write(to: sync, atomically: true, encoding: .utf8)
        store.refreshProjects()
        XCTAssertEqual(store.skillButtons(for: project.id!), ["simplify-sync"])
    }

    /// NO /ship → ALL PROJECTS would put a copy in ~/.claude/commands, which Claude Code runs before a project's own.
    func testPersonalCopyWouldReplaceAnotherProjectsOwnCommand() throws {
        let (a, b) = (try makeTempRepo(), try makeTempRepo())
        try store.addProject(at: a)
        try store.addProject(at: b)
        func ship(_ repo: URL, _ text: String) throws {
            let file = repo.appending(path: ".claude/commands/ship.md")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        try ship(a, "ship with npm")
        store.refreshProjects()
        let target = store.projects.first { $0.path != a.path && $0.path != b.path }!
        let source = store.projects.first { $0.path == a.path }!
        XCTAssertEqual(store.projectsReplaced(byCopyOf: "ship", from: source, excluding: target.id!), [],
                       "the source's own copy is the same file: nothing changes for it")
        try ship(b, "ship with gradle")
        store.refreshProjects()
        XCTAssertEqual(store.projectsReplaced(byCopyOf: "ship", from: source, excluding: target.id!).map(\.path), [b.path])
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
