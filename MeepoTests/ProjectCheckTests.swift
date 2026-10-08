import XCTest
@testable import Meepo

final class ProjectCheckTests: XCTestCase {
    private func folder(_ files: [String: String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appending(path: "check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: dir.appending(path: name), atomically: true, encoding: .utf8) }
        return dir.path
    }

    /// What CLAUDE.md says to run wins: the person wrote down how this project is checked.
    func testClaudeMdComesFirstTestsBeforeBuild() throws {
        let md = "## Build\n- Сборка: `go build ./cmd/server/`\n- Тесты: `go test ./...`\n"
        XCTAssertEqual(ProjectCheck.detect(in: try folder(["CLAUDE.md": md, "package.json": #"{"scripts":{"test":"jest"}}"#])),
                       "go test ./...")
        XCTAssertEqual(ProjectCheck.fromInstructions("- Build: `make`\n- Run: `make run`"), "make", "no tests line: the build")
        XCTAssertNil(ProjectCheck.fromInstructions("Commits in English: feat/fix prefix"))
        XCTAssertEqual(ProjectCheck.fromInstructions("- `/qa` — QA-тестирование через браузер\n- Тесты: `xcodebuild test`"),
                       "xcodebuild test", "a command that only mentions testing isn't the check (meepo's own CLAUDE.md)")
    }

    func testThePackageManagersOwnTestScript() throws {
        XCTAssertEqual(ProjectCheck.detect(in: try folder(["package.json": #"{"scripts":{"test":"vitest run"}}"#, "pnpm-lock.yaml": ""])),
                       "pnpm test")
        XCTAssertNil(ProjectCheck.detect(in: try folder(["package.json": #"{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}"#])),
                     "npm init's placeholder isn't a check")
        XCTAssertEqual(ProjectCheck.detect(in: try folder(["go.mod": "module x"])), "go build ./... && go test ./...")
        XCTAssertNil(ProjectCheck.detect(in: try folder(["README.md": "hi"])))
    }
}
