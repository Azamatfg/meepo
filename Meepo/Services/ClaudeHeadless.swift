import Foundation

/// One-off `claude -p` outside any session (release notes, EXPLAIN): the prompt goes in on stdin, the answer
/// comes back as text. Uses the default model and the user's own login.
enum ClaudeHeadless {
    /// No tools, nothing saved, no settings files (so no hooks reach Meepo's bridge).
    /// `--bare` would also skip the keychain, i.e. the subscription login.
    static let arguments = ["-p", "--tools", "", "--no-session-persistence", "--setting-sources", ""]

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// A JSON answer checked against `schema`. A fresh, empty conversation — never a fork of a session's, which
    /// re-read the whole conversation (~600k tokens a click on a long day) and after /clear explained the wrong one.
    static func jsonArguments(schema: String) -> [String] {
        arguments + ["--output-format", "json", "--json-schema", schema]
    }

    /// Returns the JSON of the answer (`structured_output`).
    static func askJSON(_ prompt: String, schema: String, claude: String, environment: [String: String]) async throws -> Data {
        let output = try await run(prompt, claude: claude, environment: environment, arguments: jsonArguments(schema: schema))
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let structured = object["structured_output"],
              let data = try? JSONSerialization.data(withJSONObject: structured) else {
            throw Failure(errorDescription: "claude -p gave no structured answer: \(output.prefix(300))")
        }
        return data
    }

    /// Runs off the main thread; the login shell's environment carries PATH (nvm) and no CLAUDE_* leftovers.
    static func run(_ prompt: String, claude: String, environment: [String: String],
                    arguments: [String] = arguments) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: claude)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = MeepoHome.url
            let input = Pipe(), out = Pipe(), err = Pipe()
            process.standardInput = input
            process.standardOutput = out
            process.standardError = err
            try process.run()
            // stderr read alongside stdout: a full stderr pipe would block claude while we wait on stdout.
            let stderr = err.fileHandleForReading
            let reading = Task.detached { stderr.readDataToEndOfFile() }
            // claude may exit before reading it all (EPIPE; SIGPIPE is ignored app-wide): its stderr says why.
            try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try? input.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errors = await reading.value
            process.waitForExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !text.isEmpty else {
                let message = String(decoding: errors.isEmpty ? data : errors, as: UTF8.self)
                throw Failure(errorDescription: "claude -p failed: \(message.prefix(300))")
            }
            return text
        }.value
    }
}
