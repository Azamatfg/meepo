import Foundation
import Security

/// `~/.meepo`: database, bridge script, token, settings backups.
enum MeepoHome {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".meepo")

    /// Owner-only (0700): prompts, replies and commands live here, which Claude Code itself keeps 0600/0700.
    static func prepare(_ dir: URL = url) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Folders made by older versions are 0755. One it can't change (another owner) must not stop the launch.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    /// Shared secret the bridge sends with every event; created on first use, readable only by the user.
    static func token(in dir: URL = url) throws -> String {
        let file = dir.appending(path: "token")
        if let existing = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try prepare(dir)
        try Data(token.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }
}
