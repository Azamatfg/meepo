import Foundation

/// Meepo's method, VERIFY: a command that proves a change in this project works, found the way a person would
/// look for it — what CLAUDE.md says to run, else the project's own test script.
enum ProjectCheck {
    /// A suggestion for the check, or nil when nothing says how this project is checked.
    static func detect(in path: String) -> String? {
        let folder = URL(filePath: path)
        func read(_ name: String) -> String? { try? String(contentsOf: folder.appending(path: name), encoding: .utf8) }
        if let command = read("CLAUDE.md").flatMap(fromInstructions) { return command }
        if let data = read("package.json")?.data(using: .utf8),
           let scripts = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["scripts"] as? [String: Any],
           let test = scripts["test"] as? String, !test.contains("no test specified") {
            let runner = [("bun.lockb", "bun"), ("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn")]
                .first { FileManager.default.fileExists(atPath: folder.appending(path: $0.0).path) }?.1 ?? "npm"
            return "\(runner) test"
        }
        if read("go.mod") != nil { return "go build ./... && go test ./..." }
        if read("Cargo.toml") != nil { return "cargo test" }
        if read("Makefile")?.range(of: #"(?m)^test:"#, options: .regularExpression) != nil { return "make test" }
        return nil
    }

    /// The command on a CLAUDE.md line labelled tests, else build: "- Tests: `npm test`", "Сборка: `go build`".
    /// Only a label right before it counts: "- `/qa` — QA-тестирование" mentions tests but isn't how to run them.
    static func fromInstructions(_ text: String) -> String? {
        for label in [#/(?i)(?:tests?|тесты?)\s*:\s*`([^`]+)`/#, #/(?i)(?:build|сборка)\s*:\s*`([^`]+)`/#] {
            if let match = text.firstMatch(of: label), !match.1.hasPrefix("/") { return String(match.1) }
        }
        return nil
    }
}
