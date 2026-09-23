import Foundation

enum BridgeError: LocalizedError {
    case unreadableSettings(String)

    var errorDescription: String? {
        switch self {
        case .unreadableSettings(let path): "Couldn’t read \(path) as JSON — file left unchanged"
        }
    }
}

/// Adds meepo-bridge.sh to `~/.claude/settings.json` next to the user's own hooks and removes it again.
/// Every write is preceded by a backup in `~/.meepo/backups/` (SPEC §3: don't break the user's setup).
struct BridgeInstaller {
    var settingsURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
    var meepoHome = MeepoHome.url

    /// Events that drive statuses, notifications and the feed.
    static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure", "PreCompact",
        "UserPromptExpansion",
    ]
    static let scriptName = "meepo-bridge.sh"

    var scriptURL: URL { meepoHome.appending(path: "bin/\(Self.scriptName)") }

    /// Exits at once for sessions Meepo didn't start (no MEEPO_SESSION_ID), and silently when Meepo isn't running.
    /// Synchronous on purpose: `async: true` hooks were dropped when claude exited (checked on 2.1.280).
    static let script = """
    #!/bin/bash
    # Meepo hook bridge: forwards Claude Code hook events to Meepo (https://github.com/Azamatfg/meepo).
    # Installed by Meepo; remove it from Meepo ("Remove Hook Bridge"), not by hand.
    [ -z "$MEEPO_SESSION_ID" ] && exit 0
    TOKEN=$(cat "$HOME/.meepo/token" 2>/dev/null) || exit 0
    curl -s -m 2 -X POST "http://127.0.0.1:${MEEPO_PORT:-47800}/event" \\
      -H "Content-Type: application/json" -H "X-Meepo-Token: $TOKEN" -H "X-Meepo-Session: $MEEPO_SESSION_ID" \\
      --data-binary @- >/dev/null 2>&1
    exit 0

    """

    func isInstalled() -> Bool {
        guard let hooks = (try? readSettings())?["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { Self.isBridge($0) }
            }
        }
    }

    /// True when every event Meepo needs has the bridge (a newer Meepo may subscribe to more events).
    func isUpToDate() -> Bool {
        guard let hooks = (try? readSettings())?["hooks"] as? [String: Any] else { return false }
        return Self.events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { Self.isBridge($0) }
            }
        }
    }

    private static func isBridge(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.contains(scriptName) ?? false
    }

    /// Idempotent: replaces any previous bridge entries. Returns the backup, if there was a file to back up.
    @discardableResult
    func install() throws -> URL? {
        try writeScript()
        var settings = try readSettings()
        var hooks = Self.removingBridge(from: settings["hooks"] as? [String: Any] ?? [:])
        let entry: [String: Any] = ["hooks": [["type": "command", "command": scriptURL.path, "timeout": 5]]]
        for event in Self.events {
            hooks[event] = (hooks[event] as? [Any] ?? []) + [entry]
        }
        settings["hooks"] = hooks
        return try write(settings)
    }

    @discardableResult
    func uninstall() throws -> URL? {
        var settings = try readSettings()
        guard let hooks = settings["hooks"] as? [String: Any] else { return nil }
        let cleaned = Self.removingBridge(from: hooks)
        if cleaned.isEmpty { settings["hooks"] = nil } else { settings["hooks"] = cleaned }
        return try write(settings)
    }

    /// Quiets the user's own Notification hooks (global and per project) in Meepo sessions, or restores them.
    func setNotifyGuard(_ enabled: Bool, projectPaths: [String]) throws {
        let files = [settingsURL] + projectPaths.flatMap(NotifyGuard.settingsFiles(ofProject:))
        for file in files {
            try NotifyGuard.apply(enabled, to: file, backupDir: meepoHome.appending(path: "backups"))
        }
    }

    /// Keeps the script current after Meepo updates.
    func writeScript() throws {
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Drops only handlers whose command is our script; groups/events left empty by that go too.
    static func removingBridge(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { result[event] = value; continue }
            var removedAny = false
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let rest = handlers.filter { !isBridge($0) }
                guard rest.count != handlers.count else { return group }
                removedAny = true
                if rest.isEmpty { return nil }
                var group = group
                group["hooks"] = rest
                return group
            }
            if !(removedAny && kept.isEmpty) { result[event] = kept }
        }
        return result
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.unreadableSettings(settingsURL.path)
        }
        return object
    }

    private func write(_ settings: [String: Any]) throws -> URL? {
        let target = settingsURL.resolvingSymlinksInPath()
        var backup: URL?
        if FileManager.default.fileExists(atPath: target.path) {
            let dir = meepoHome.appending(path: "backups")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            backup = dir.appending(path: "settings-\(stamp)-\(UUID().uuidString.prefix(4)).json")
            try FileManager.default.copyItem(at: target, to: backup!)
        } else {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: target, options: .atomic)
        return backup
    }
}
