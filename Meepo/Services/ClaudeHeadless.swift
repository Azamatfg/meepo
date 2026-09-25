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

    /// A fork of an existing conversation (`--resume <id> --fork-session`) answers a question in its own context
    /// — the session itself is untouched — with a JSON answer checked against `schema`. Returns the JSON.
    static func askFork(of sessionId: String, in folder: String, prompt: String, schema: String,
                        claude: String, environment: [String: String]) async throws -> Data {
        let output = try await run(prompt, claude: claude, environment: environment, folder: folder,
                                   arguments: arguments + ["--resume", sessionId, "--fork-session",
                                                           "--output-format", "json", "--json-schema", schema])
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let structured = object["structured_output"],
              let data = try? JSONSerialization.data(withJSONObject: structured) else {
            throw Failure(errorDescription: "claude -p gave no structured answer: \(output.prefix(300))")
        }
        return data
    }

    /// Runs off the main thread; the login shell's environment carries PATH (nvm) and no CLAUDE_* leftovers.
    static func run(_ prompt: String, claude: String, environment: [String: String],
                    folder: String? = nil, arguments: [String] = arguments) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: claude)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = folder.map { URL(filePath: $0) } ?? MeepoHome.url
            let input = Pipe(), out = Pipe(), err = Pipe()
            process.standardInput = input
            process.standardOutput = out
            process.standardError = err
            try process.run()
            input.fileHandleForWriting.write(Data(prompt.utf8))
            try input.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
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
