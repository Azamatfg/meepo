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

    /// Runs off the main thread; the login shell's environment carries PATH (nvm) and no CLAUDE_* leftovers.
    static func run(_ prompt: String, claude: String, environment: [String: String]) async throws -> String {
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
