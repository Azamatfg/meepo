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

    func testRunsThroughInteractiveLoginShellWithQuotedArgs() {
        let launch = ClaudeLauncher.shellLaunch(claudeArgs: ["--session-id", id, "it's $HOME; rm -rf /"], shell: "/bin/zsh")
        XCTAssertEqual(launch.executable, "/bin/zsh")
        XCTAssertEqual(launch.args.prefix(3), ["-l", "-i", "-c"])
        XCTAssertEqual(launch.args[3], #"exec claude '--session-id' '\#(id)' 'it'\''s $HOME; rm -rf /'"#)
    }

    func testQuotedPromptReachesClaudeAsOneLiteralArgument() throws {
        // Run the real shell with `printf` standing in for claude: proves quoting survives zsh.
        let prompt = "it's \"$HOME\" `whoami`\nline2"
        let command = "printf %s " + ClaudeLauncher.shellQuote(prompt)
        let p = Process()
        p.executableURL = URL(filePath: "/bin/zsh")
        p.arguments = ["-f", "-c", command]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), prompt)
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
