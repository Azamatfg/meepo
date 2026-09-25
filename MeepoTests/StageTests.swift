import GRDB
import XCTest
@testable import Meepo

final class CommandCatalogTests: XCTestCase {
    func testProjectGlobalSkillsNestedAndBuiltIns() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "cat-\(UUID().uuidString)")
        let home = base.appending(path: "home"), project = base.appending(path: "project")
        func write(_ url: URL, _ text: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(home.appending(path: ".claude/commands/plan.md"), "---\ndescription: global plan\n---\nbody")
        try write(home.appending(path: ".claude/commands/retro.md"), "\n# Retro — session retrospective\n\nBody")
        try write(project.appending(path: ".claude/commands/plan.md"), "---\ndescription: \"Project plan\"\n---\n")
        try write(project.appending(path: ".claude/commands/git/ship.md"), "---\ndescription: ship it\n---\n")
        try write(project.appending(path: ".claude/skills/qa/SKILL.md"), "---\nname: qa\ndescription: QA via browser\n---\n")

        let commands = CommandCatalog.commands(projectPath: project.path, home: home)
        let byName = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0.description) })
        XCTAssertEqual(Set(byName.keys), ["plan", "retro", "git:ship", "qa", "simplify"])
        XCTAssertEqual(byName["plan"]!, "Project plan") // project overrides global
        XCTAssertEqual(byName["retro"]!, "Retro — session retrospective") // no frontmatter: first line, like Claude Code
        XCTAssertEqual(byName["qa"]!, "QA via browser")
    }

    func testRemoteControlFlagCarriesReadableName() {
        XCTAssertEqual(ClaudeLauncher.claudeArguments(sessionId: "id", resume: true, model: nil, remoteControl: "MDS · main", prompt: "x"),
                       ["--resume", "id", "--remote-control", "MDS · main"])
    }

    func testEffortFlag() {
        XCTAssertEqual(ClaudeLauncher.claudeArguments(sessionId: "id", resume: false, model: "opus", effort: "max", prompt: nil),
                       ["--session-id", "id", "--model", "opus", "--effort", "max"])
    }
}

@MainActor
final class StageFlowTests: XCTestCase {
    private var db: DatabaseQueue!
    private var store: AppStore!
    private var project: Project!

    override func setUp() async throws {
        db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "st-\(UUID().uuidString)")
        store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                         usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        let repo = try makeTempRepo()
        for name in ["plan", "qa", "ship", "sync"] {
            let file = repo.appending(path: ".claude/commands/\(name).md")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "---\ndescription: \(name)\n---\n".write(to: file, atomically: true, encoding: .utf8)
        }
        try store.addProject(at: repo)
        project = store.projects[0]
        store.refreshProjects()
        try store.createSession(projectId: project.id!, model: "sonnet", prompt: nil)
    }

    private var session: Session { store.sessions.last! }

    private func send(_ event: String, prompt: String? = nil, command: String? = nil, tool: String? = nil,
                      target: String? = nil, reply: String? = nil, to id: Int64? = nil) {
        store.handleHookEvent(HookPayload(event: event, claudeSessionId: session.claudeSessionId, prompt: prompt,
                                          toolName: tool, toolTarget: target, lastAssistantMessage: reply, commandName: command),
                              sessionId: id ?? session.id!)
    }

    func testContextWindowsFollowClaudeCode() {
        XCTAssertEqual(AppStore.nativeWindow("claude-opus-5-5"), 1_000_000)
        XCTAssertEqual(AppStore.nativeWindow("claude-sonnet-5-20260601"), 1_000_000)
        XCTAssertEqual(AppStore.nativeWindow("claude-sonnet-4-6"), 200_000)
        XCTAssertEqual(AppStore.nativeWindow("claude-sonnet-4-6[1m]"), 1_000_000)
        store.contextWindows["claude-opus-5-5"] = 200_000
        XCTAssertEqual(store.contextWindow(for: "claude-opus-5-5"), 200_000, "a size set by hand wins")
    }

    func testPlanToCodeAndRelayStayInTheWorktree() throws {
        try store.createSession(projectId: project.id!, model: "opus", prompt: nil, stage: "plan", worktree: "login")
        let planner = session
        send("UserPromptExpansion", command: "plan")
        send("Stop", reply: "1. Do it")
        try store.startImplementation(from: planner.id!)
        let coder = store.sessions.last!
        XCTAssertEqual(coder.worktreeName, "login", "code goes on in the plan's worktree, not the main folder")
        XCTAssertEqual(coder.branch, planner.branch)
        XCTAssertNotEqual(coder.portBase, planner.portBase, "both run at once, so their own ports")

        store.relay(coder.id!)
        send("Stop", reply: "handoff", to: coder.id!)
        let relayed = store.sessions.last!
        XCTAssertNotEqual(relayed.id, coder.id)
        XCTAssertEqual(relayed.worktreeName, "login")
        XCTAssertEqual(relayed.portBase, coder.portBase, "the old one closed; its ports carry over")
        XCTAssertFalse(store.sessions.contains { $0.id == coder.id })
    }

    func testOnlyStagesWhoseCommandsExistAreOffered() {
        // security and simplify: security missing; simplify is a Claude Code built-in.
        XCTAssertEqual(store.stages(for: project.id!).map(\.name), ["plan", "code", "qa", "simplify", "ship", "sync"])
    }

    func testStageFollowsCommandsAndPlainPromptAfterPlanIsCode() {
        send("UserPromptExpansion", prompt: "/plan add login", command: "plan")
        XCTAssertEqual(session.stage, "plan")
        send("UserPromptSubmit", prompt: "/plan add login")        // the same command's submit: still plan
        XCTAssertEqual(session.stage, "plan")
        send("UserPromptSubmit", prompt: "ok, go")
        XCTAssertEqual(session.stage, "code")
        send("UserPromptExpansion", prompt: "/qa", command: "qa")
        send("UserPromptSubmit", prompt: "also check the form")   // after qa a plain prompt doesn't jump
        XCTAssertEqual(session.stage, "qa")
    }

    func testPlanHandsOffToFreshSessionOnCodeStageModel() throws {
        store.stages[1].model = "haiku" // code stage
        let planner = session.id!
        send("UserPromptExpansion", prompt: "/plan x", command: "plan")
        send("UserPromptSubmit", prompt: "/plan x")
        send("Stop", reply: "1. Add form\n2. Add API")
        XCTAssertTrue(store.canStartImplementation(store.sessions.first { $0.id == planner }!))
        try store.startImplementation(from: planner, notes: "a, yes, start with phase 1")
        let coder = session
        XCTAssertNotEqual(coder.id, planner)
        XCTAssertEqual(coder.stage, "code")
        XCTAssertEqual(coder.model, "haiku")
        XCTAssertTrue(store.initialPrompts[coder.id!]!.contains("1. Add form\n2. Add API"))
        XCTAssertTrue(store.initialPrompts[coder.id!]!.hasSuffix("a, yes, start with phase 1")) // decisions come after the plan
    }

    /// SPEC module 4 "done when": a session at 75% context is replaced by a fresh one that continues the task.
    func testRelayReplacesFullSessionWithFreshOneCarryingTheSync() {
        let old = session
        send("UserPromptExpansion", prompt: "/plan x", command: "plan")
        store.relay(old.id!)
        XCTAssertTrue(store.relayingSessionIds.contains(old.id!))
        XCTAssertNil(store.handleHookEvent(
            HookPayload(event: "Stop", claudeSessionId: old.claudeSessionId, lastAssistantMessage: "Task: login. Done: form. Next: API."),
            sessionId: old.id!)) // no "done" notification for a session that is being replaced
        XCTAssertFalse(store.sessions.contains { $0.id == old.id })
        let fresh = session
        XCTAssertEqual(fresh.projectId, old.projectId)
        XCTAssertEqual(fresh.model, old.model)
        XCTAssertEqual(fresh.stage, "plan")
        XCTAssertNotEqual(fresh.claudeSessionId, old.claudeSessionId)
        XCTAssertTrue(store.initialPrompts[fresh.id!]!.contains("Next: API."))
        XCTAssertEqual(store.selectedSessionId, fresh.id)
    }

    func testShipReminderWhenCodeChangedAfterQA() async throws {
        send("PostToolUse", tool: "Edit", target: "/a.swift")
        XCTAssertTrue(store.codeChangedSinceQA(session.id!))
        try await Task.sleep(for: .milliseconds(5))
        send("UserPromptExpansion", prompt: "/qa", command: "qa")
        XCTAssertFalse(store.codeChangedSinceQA(session.id!))
        try await Task.sleep(for: .milliseconds(5))
        send("PostToolUse", tool: "Write", target: "/b.swift")
        XCTAssertTrue(store.codeChangedSinceQA(session.id!))
    }
}

final class BridgeUpgradeTests: XCTestCase {
    func testOlderInstallMissingAnEventIsNotUpToDate() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "up-\(UUID().uuidString)")
        let installer = BridgeInstaller(settingsURL: dir.appending(path: "settings.json"), meepoHome: dir)
        try installer.install()
        XCTAssertTrue(installer.isUpToDate())
        var settings = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.settingsURL)) as! [String: Any]
        var hooks = settings["hooks"] as! [String: Any]
        hooks["UserPromptExpansion"] = nil // what a module-2 install looked like
        settings["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: settings).write(to: installer.settingsURL)
        XCTAssertTrue(installer.isInstalled())
        XCTAssertFalse(installer.isUpToDate())
    }
}

@MainActor
final class CommandCopyTests: XCTestCase {
    func testCopyToProjectOrGlobalNeverOverwrites() throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "cc-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: tmp.appending(path: "s.json"), meepoHome: tmp),
                             usageRoot: tmp, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        let withPlan = try makeTempRepo(), without = try makeTempRepo()
        let plan = withPlan.appending(path: ".claude/commands/plan.md")
        try FileManager.default.createDirectory(at: plan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "plan v1".write(to: plan, atomically: true, encoding: .utf8)
        try store.addProject(at: withPlan)
        try store.addProject(at: without)
        let source = store.projects.first { $0.path == withPlan.path }!
        let target = store.projects.first { $0.path == without.path }!

        XCTAssertEqual(store.commandSources("plan", excluding: target.id!).map(\.id), [source.id])
        store.copyCommand("plan", from: source, toProject: target, home: tmp)
        XCTAssertEqual(try String(contentsOf: without.appending(path: ".claude/commands/plan.md"), encoding: .utf8), "plan v1")
        XCTAssertTrue(store.stages(for: target.id!).contains { $0.name == "plan" })

        let global = tmp.appending(path: ".claude/commands/plan.md")
        try FileManager.default.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "user's own global plan".write(to: global, atomically: true, encoding: .utf8)
        store.copyCommand("plan", from: source, toProject: nil, home: tmp)
        XCTAssertEqual(try String(contentsOf: global, encoding: .utf8), "user's own global plan")
    }
}

/// After Meepo is deleted its hook entries must not break Claude Code (brew uninstall --zap takes ~/.meepo).
final class BridgeCommandTests: XCTestCase {
    private func run(_ command: String, input: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testAMissingScriptIsASilentSuccess() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gone \(UUID().uuidString)") // a space, too
        let installer = BridgeInstaller(settingsURL: dir.appending(path: "settings.json"), meepoHome: dir)
        let result = try run(installer.hookCommand, input: "{}")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "")
    }

    func testThePresentScriptGetsStdinAndItsReplyComesOut() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "here \(UUID().uuidString)")
        let installer = BridgeInstaller(settingsURL: dir.appending(path: "settings.json"), meepoHome: dir)
        try FileManager.default.createDirectory(at: installer.scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\ncat\n".write(to: installer.scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installer.scriptURL.path)
        XCTAssertEqual(try run(installer.hookCommand, input: "reply for claude").output, "reply for claude")
    }

    func testABareScriptPathFromAnOlderMeepoGetsReplaced() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "old-\(UUID().uuidString)")
        let installer = BridgeInstaller(settingsURL: dir.appending(path: "settings.json"), meepoHome: dir)
        let bare: [String: Any] = ["hooks": [["type": "command", "command": installer.scriptURL.path, "timeout": 5]]]
        let old = ["hooks": Dictionary(uniqueKeysWithValues: BridgeInstaller.events.map { ($0, [bare]) })]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: old).write(to: installer.settingsURL)
        XCTAssertTrue(installer.isInstalled())
        XCTAssertFalse(installer.isUpToDate(), "an old bare path fails hooks once ~/.meepo is gone")
        try installer.install()
        XCTAssertTrue(installer.isUpToDate())
    }
}
