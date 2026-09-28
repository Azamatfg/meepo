import Foundation

/// Keeps the user's own Notification hooks quiet inside Meepo sessions, so Meepo's notification
/// (project, branch, text, click-to-open) is the only one. Outside Meepo `MEEPO_SESSION_ID` is unset
/// and the hook runs exactly as before. A hook in exec form (`args`, no shell) can't be guarded: it still
/// notifies inside Meepo too.
///
/// Edits the command string in place rather than re-serialising the JSON, so a project's
/// settings.json keeps its formatting and its git diff is one line.
enum NotifyGuard {
    /// `exit` rather than `||`: `||` would skip only the first part of `a && b` or `a; b`.
    static let prefix = #"[ -n "$MEEPO_SESSION_ID" ] && exit 0; "#
    /// The guard Meepo wrote before; still recognised so it can be replaced or taken back.
    private static let legacyPrefix = #"[ -n "$MEEPO_SESSION_ID" ] || "#

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
        let backup = backupDir.appending(path: "\(name)-\(file.lastPathComponent)-\(UUID().uuidString.prefix(8))")
        try data.write(to: backup)
        try Data(updated.utf8).write(to: file.resolvingSymlinksInPath(), options: .atomic)
        ChangeLog.record(enabled ? "Quiet own Notification hooks in meepo" : "Restore own Notification hooks",
                         file: file.resolvingSymlinksInPath(), backup: backup, backups: backupDir)
        return changed
    }

    static func guarded(_ text: String) -> (String, Int) {
        rewrite(text) { command, exec in
            // Exec form resolves `command` as an executable: a guard there breaks the hook everywhere, so take it off.
            if exec { return stripped(command) }
            return command.hasPrefix(prefix) ? nil : prefix + (stripped(command) ?? command)
        }
    }

    static func unguarded(_ text: String) -> (String, Int) {
        rewrite(text) { command, _ in stripped(command) }
    }

    /// The command without Meepo's guard (today's or the older one); nil when it has none.
    private static func stripped(_ command: String) -> String? {
        for guardText in [prefix, legacyPrefix] where command.hasPrefix(guardText) {
            return String(command.dropFirst(guardText.count))
        }
        return nil
    }

    /// Notification hook commands, except Meepo's own bridge; `exec`: the handler has `args` (run without a shell).
    static func notificationCommands(in text: String) -> [(command: String, exec: Bool)] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let groups = (json["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]] else { return [] }
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { handler in (handler["command"] as? String).map { (command: $0, exec: handler["args"] != nil) } }
            .filter { !$0.command.contains(BridgeInstaller.scriptName) }
    }

    /// Replaces each command's JSON string literal when it occurs exactly once in the file;
    /// an ambiguous command (also used by another event) is skipped rather than guessed.
    private static func rewrite(_ text: String, _ transform: (String, Bool) -> String?) -> (String, Int) {
        var text = text
        var changed = 0
        for (command, exec) in notificationCommands(in: text) {
            guard let replacement = transform(command, exec) else { continue }
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
