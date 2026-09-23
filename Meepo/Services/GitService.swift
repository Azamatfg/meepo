import Foundation

enum GitError: LocalizedError, Equatable {
    case notARepository(String)

    var errorDescription: String? {
        switch self {
        case .notARepository(let path): "Not a git repository: \(path)"
        }
    }
}

enum GitService {
    /// Top-level folder of the repository containing `path` (so picking a subfolder still adds the repo).
    static func repositoryRoot(of path: String) throws -> String {
        guard let root = run(["rev-parse", "--show-toplevel"], in: path) else {
            throw GitError.notARepository(path)
        }
        return root
    }

    static func remoteURL(in path: String) -> String? {
        run(["remote", "get-url", "origin"], in: path)
    }

    static func currentBranch(in path: String) -> String? {
        run(["branch", "--show-current"], in: path)
    }

    static func hasUncommittedChanges(in path: String) -> Bool {
        run(["status", "--porcelain"], in: path) != nil
    }

    /// Runs git and returns trimmed stdout, or nil on failure or empty output.
    private static func run(_ args: [String], in path: String) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", path] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
