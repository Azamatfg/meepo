import Foundation
import Security

/// `~/.meepo`: database, bridge script, token, settings backups.
enum MeepoHome {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".meepo")

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
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(token.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }
}
