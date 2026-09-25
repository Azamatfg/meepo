import XCTest
@testable import Meepo

final class SetupCheckTests: XCTestCase {
    private func apply(_ finding: SetupCheck.Finding, to settings: [String: Any], undo: Bool = false) -> [String: Any] {
        guard case let .settings(apply, revert) = finding.fix else { XCTFail("not a settings fix"); return settings }
        var copy = settings
        (undo ? revert : apply)(&copy)
        return copy
    }

    /// The case found on 2026-09-25: effortLevel xhigh, but nothing for Opus 5.5 → it ran at medium.
    func testEffortThatDoesntReachTheModelInUse() throws {
        let settings: [String: Any] = ["effortLevel": "xhigh", "modelSettings": ["claude-opus-5": ["effortLevel": "xhigh"]]]
        let finding = try XCTUnwrap(SetupCheck.effort(settings, "claude-opus-5-5").first)
        let fixed = apply(finding, to: settings)
        XCTAssertEqual(((fixed["modelSettings"] as? [String: Any])?["claude-opus-5-5"] as? [String: Any])?["effortLevel"] as? String, "xhigh")
        XCTAssertTrue(SetupCheck.effort(fixed, "claude-opus-5-5").isEmpty, "fixed means no longer found")
        XCTAssertEqual(apply(finding, to: fixed, undo: true) as NSDictionary, settings as NSDictionary, "undo puts it back exactly")
        XCTAssertTrue(SetupCheck.effort(settings, "claude-opus-5").isEmpty, "a model with its own level is fine")
        XCTAssertTrue(SetupCheck.effort(["modelSettings": [:]], "claude-opus-5-5").isEmpty, "no global level, nothing lost")
    }

    func testMillisecondHookTimeouts() throws {
        let settings: [String: Any] = ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": "init.sh", "timeout": 10000],
                                                                               ["type": "command", "command": "ok.sh", "timeout": 30]]]]]]
        let findings = SetupCheck.hookTimeouts(settings)
        XCTAssertEqual(findings.count, 1, "30 s is a real timeout")
        XCTAssertEqual(findings[0].title, "A SessionStart hook may hang for 2.8 hours")
        let fixed = apply(findings[0], to: settings)
        XCTAssertTrue(SetupCheck.hookTimeouts(fixed).isEmpty)
        XCTAssertEqual(apply(findings[0], to: fixed, undo: true) as NSDictionary, settings as NSDictionary)
    }

    func testBroadAllowRulesButNotNarrowOnes() {
        let settings: [String: Any] = ["permissions": ["allow": ["Bash(sudo:*)", "Bash(npm test:*)", "Read"]]]
        let findings = SetupCheck.broadPermissions(settings)
        XCTAssertEqual(findings.map(\.title), ["Claude may run Bash(sudo:*) without asking"])
        let fixed = apply(findings[0], to: settings)
        XCTAssertEqual((fixed["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(npm test:*)", "Read"])
    }

    func testShippingSkillsWithoutAGuard() {
        let dir = URL(filePath: "/tmp/x")
        let commands: [(url: URL, text: String)] = [
            (dir.appending(path: "ship.md"), "---\ndescription: ship\n---\nRun tests, git commit, git push."),
            (dir.appending(path: "safe.md"), "---\ndisable-model-invocation: true\n---\ngit push"),
            (dir.appending(path: "plan.md"), "Just plan."),
        ]
        XCTAssertEqual(SetupCheck.unguardedShipping(commands).map(\.title), ["Claude can run /ship by itself"])
    }

    func testManualOnlyRoundTrips() {
        for text in ["---\ndescription: ship\n---\nbody", "No frontmatter\nbody"] {
            let on = SetupCheck.setManualOnly(text, true)
            XCTAssertTrue(on.contains("disable-model-invocation: true"))
            XCTAssertEqual(SetupCheck.setManualOnly(on, false), text)
        }
    }
}
