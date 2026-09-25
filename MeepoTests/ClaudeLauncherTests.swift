import XCTest
@testable import Meepo

final class ClaudeLauncherTests: XCTestCase {
    private let id = "0b6f7c2e-1111-4222-8333-944455556666"

    func testNewSessionPinsIdAndPassesModelAndPrompt() {
        let args = ClaudeLauncher.claudeArguments(sessionId: id, resume: false, model: "opus", prompt: "fix login")
        XCTAssertEqual(args, ["--session-id", id, "--model", "opus", "fix login"])
    }

    func testResumeNeverResendsInitialPrompt() {
        let args = ClaudeLauncher.claudeArguments(sessionId: id, resume: true, model: "sonnet", prompt: "fix login")
        XCTAssertEqual(args, ["--resume", id, "--model", "sonnet"])
    }

    func testDefaultModelAddsNoFlag() {
        XCTAssertEqual(ClaudeLauncher.claudeArguments(sessionId: id, resume: false, model: nil, prompt: nil),
                       ["--session-id", id])
    }

    func testTranscriptFoundInAnyProjectFolder() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "claude-home-\(UUID().uuidString)")
        let folder = home.appending(path: "projects/-Users-me-------")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(ClaudeLauncher.hasTranscript(sessionId: id, claudeHome: home))
        FileManager.default.createFile(atPath: folder.appending(path: "\(id).jsonl").path, contents: Data())
        XCTAssertTrue(ClaudeLauncher.hasTranscript(sessionId: id, claudeHome: home))
    }

    func testEnvironmentDropsParentClaudeSessionAndHostTerminal() {
        let env = ClaudeLauncher.scrubbed([
            "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SESSION_ID": "x",
            "CLAUDE_PID": "42", "AI_AGENT": "claude",
            "TERM_PROGRAM": "vscode", "TERM_PROGRAM_VERSION": "1.137.0", "VSCODE_INJECTION": "1",
            "GIT_ASKPASS": "/Applications/Visual Studio Code.app/askpass.sh",
            "ANTHROPIC_BASE_URL": "https://proxy", "HOME": "/Users/me",
        ])
        XCTAssertEqual(env, ["ANTHROPIC_BASE_URL": "https://proxy", "HOME": "/Users/me"])
    }

    func testLoginEnvironmentIgnoresShellNoiseAndKeepsZshrcVars() {
        let m = ClaudeLauncher.loginMarker
        let output = "Welcome! conda activated\n\(m)/Users/me/.nvm/bin/claude\n\(m)PATH=/Users/me/.nvm/bin:/usr/bin\0CLAUDE_CONFIG_DIR=/cfg\0A=x=y\0\(m)"
        XCTAssertEqual(ClaudeLauncher.parseLoginEnvironment(output), .init(
            claudePath: "/Users/me/.nvm/bin/claude",
            environment: ["PATH": "/Users/me/.nvm/bin:/usr/bin", "CLAUDE_CONFIG_DIR": "/cfg", "A": "x=y"]
        ))
    }

    func testLoginEnvironmentRejectsAliasInsteadOfBinary() {
        let m = ClaudeLauncher.loginMarker
        XCTAssertNil(ClaudeLauncher.parseLoginEnvironment("\(m)claude\n\(m)PATH=/usr/bin\0\(m)"))
        XCTAssertNil(ClaudeLauncher.parseLoginEnvironment("\(m)\n\(m)PATH=/usr/bin\0\(m)")) // not installed
    }

    func testRealLoginShellFindsClaude() throws {
        // Needs claude installed for the current user; that's the whole point of Meepo.
        let login = try XCTUnwrap(ClaudeLauncher.resolveLoginEnvironment())
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: login.claudePath))
        XCTAssertNil(login.environment["CLAUDE_CODE_CHILD_SESSION"])
        XCTAssertNil(login.environment["VSCODE_INJECTION"])
    }

    func testEnvironmentForcesTerminalTypeAndKeepsPath() {
        let env = ClaudeLauncher.environment(base: ["PATH": "/usr/bin", "TERM": "dumb"])
        XCTAssertTrue(env.contains("TERM=xterm-256color"))
        XCTAssertTrue(env.contains("PATH=/usr/bin"))
        XCTAssertTrue(env.contains("LANG=en_US.UTF-8"))
    }
}

/// A ~/.zshrc that waits forever used to leave every session an empty terminal.
final class LoginTimeoutTests: XCTestCase {
    func testHangingShellGivesUpInsteadOfBlockingForever() throws {
        let shell = FileManager.default.temporaryDirectory.appending(path: "hang-\(UUID().uuidString).sh")
        try "#!/bin/sh\nsleep 30\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let start = Date.now
        XCTAssertNil(ClaudeLauncher.resolveLoginEnvironment(shell: shell.path, timeout: 1))
        XCTAssertLessThan(Date.now.timeIntervalSince(start), 5)
    }
}

final class SessionSettingsTests: XCTestCase {
    func testUltracodeIsASettingNeverAnEffortFlag() throws {
        let args = ClaudeLauncher.claudeArguments(sessionId: "id", resume: false, model: nil, effort: "ultracode", prompt: nil)
        XCTAssertFalse(args.contains("--effort"), "claude 2.1.282 ignores --effort ultracode with a warning")
        let settings = ClaudeLauncher.sessionSettings(effort: "ultracode")
        let json = try JSONSerialization.jsonObject(with: Data(settings[1].utf8)) as? [String: Any]
        XCTAssertEqual(json?["ultracode"] as? Bool, true)
        XCTAssertEqual(json?["theme"] as? String, "light")
    }

    func testOtherEffortsStayFlags() throws {
        let args = ClaudeLauncher.claudeArguments(sessionId: "id", resume: false, model: nil, effort: "xhigh", prompt: nil)
        XCTAssertEqual(Array(args.suffix(2)), ["--effort", "xhigh"])
        let json = try JSONSerialization.jsonObject(with: Data(ClaudeLauncher.sessionSettings(effort: "xhigh")[1].utf8)) as? [String: Any]
        XCTAssertNil(json?["ultracode"])
    }
}
