import Foundation

/// Keeps the user's own Notification hooks quiet inside Meepo sessions, so Meepo's notification
/// (project, branch, text, click-to-open) is the only one. Outside Meepo `MEEPO_SESSION_ID` is unset
/// and the hook runs exactly as before.
///
/// Edits the command string in place rather than re-serialising the JSON, so a project's
/// settings.json keeps its formatting and its git diff is one line.
enum NotifyGuard {
    static let prefix = #"[ -n "$MEEPO_SESSION_ID" ] || "#

    static func settingsFiles(ofProject path: String) -> [URL] {
        let dir = URL(filePath: path).appending(path: ".claude")
        return [dir.appending(path: "settings.json"), dir.appending(path: "settings.local.json")]
    }

    /// Guards (or unguards) every Notification hook command in the file; backs the file up first.
    /// Returns how many commands changed. Missing or unparsable files are left alone.
    @discardableResult
    static func apply(_ enabled: Bool, to file: URL, backupDir: URL) throws -> Int {
        guard let data = try? Data(contentsOf: file) else { return 0 }
        let text = String(decoding: data, as: UTF8.self)
        let (updated, changed) = enabled ? guarded(text) : unguarded(text)
        guard changed > 0 else { return 0 }
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let name = file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        try data.write(to: backupDir.appending(path: "\(name)-\(file.lastPathComponent)-\(UUID().uuidString.prefix(8))"))
        try Data(updated.utf8).write(to: file.resolvingSymlinksInPath(), options: .atomic)
        return changed
    }

    static func guarded(_ text: String) -> (String, Int) {
        rewrite(text) { $0.hasPrefix(prefix) ? nil : prefix + $0 }
    }

    static func unguarded(_ text: String) -> (String, Int) {
        rewrite(text) { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
    }

    /// Notification hook commands, except Meepo's own bridge.
    static func notificationCommands(in text: String) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let groups = (json["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]] else { return [] }
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
            .filter { !$0.contains(BridgeInstaller.scriptName) }
    }

    /// Replaces each command's JSON string literal when it occurs exactly once in the file;
    /// an ambiguous command (also used by another event) is skipped rather than guessed.
    private static func rewrite(_ text: String, _ transform: (String) -> String?) -> (String, Int) {
        var text = text
        var changed = 0
        for command in notificationCommands(in: text) {
            guard let replacement = transform(command) else { continue }
            for escapeSlashes in [false, true] {
                let old = literal(command, escapeSlashes: escapeSlashes)
                guard text.components(separatedBy: old).count == 2 else { continue }
                text = text.replacingOccurrences(of: old, with: literal(replacement, escapeSlashes: escapeSlashes))
                changed += 1
                break
            }
        }
        return (text, changed)
    }

    private static func literal(_ string: String, escapeSlashes: Bool) -> String {
        let options: JSONSerialization.WritingOptions = escapeSlashes ? [.fragmentsAllowed] : [.fragmentsAllowed, .withoutEscapingSlashes]
        let data = (try? JSONSerialization.data(withJSONObject: string, options: options)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
