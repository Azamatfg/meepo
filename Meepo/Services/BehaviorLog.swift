import AppKit

/// How the user works, one JSON object per line in ~/.meepo/behavior.jsonl — written only, read later to suggest
/// improvements. Each line has `t` (ISO 8601 with the date) and `kind`:
///   view     what the window shows changed: `field` (session, home, preset, settings, whatChanged) and `value`
///   key      a shortcut (⌘ or ⌃ with a key) or Esc, and the view that got it — plain typing is never written
///   app      Meepo became active or went to the background; `screen` — the screens slept, woke, locked
///   hook     a Claude Code event the user is part of: a prompt (its first 500 characters), a stop, a permission
///            request, a question; with the session, its project and how many sessions are mid-turn
@MainActor
enum BehaviorLog {
    private static var keyMonitor: Any?
    private static var last: [String: String] = [:]
    nonisolated private static let queue = DispatchQueue(label: "meepo.behavior")
    nonisolated private static let file: FileHandle? = {
        let url = URL.homeDirectory.appending(path: ".meepo/behavior.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()
    /// Events that are Claude's own work, not the user's: left out.
    static let skippedEvents: Set = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop",
                                     "PreCompact", "PostCompact", "UserPromptExpansion"]

    static func start(store: AppStore) {
        write("app", ["state": "launch"])
        last = viewState(store)
        observe(store)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let isEscape = event.keyCode == 53
            guard isEscape || mods.contains(.command) || mods.contains(.control) else { return event }
            let view = event.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
            let key = isEscape ? "esc" : symbols(mods) + (event.charactersIgnoringModifiers ?? "?")
            write("key", ["key": key, "in": view])
            return event
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            write("app", ["state": "active"])
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            write("app", ["state": "background"])
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, state) in [(NSWorkspace.screensDidSleepNotification, "sleep"), (NSWorkspace.screensDidWakeNotification, "wake"),
                              (NSWorkspace.sessionDidResignActiveNotification, "locked"),
                              (NSWorkspace.sessionDidBecomeActiveNotification, "unlocked")] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in write("screen", ["state": state]) }
        }
    }

    static func hook(_ payload: HookPayload, sessionId: Int64, store: AppStore) {
        guard !skippedEvents.contains(payload.event) || payload.isQuestion else { return }
        var fields = ["event": payload.event, "session": String(sessionId),
                      "working": String(store.workingSessionIds.count)]
        if let session = store.sessions.first(where: { $0.id == sessionId }) {
            fields["project"] = store.project(for: session)?.name
        }
        fields["tool"] = payload.toolName
        fields["target"] = payload.toolTarget
        fields["type"] = payload.notificationType
        if let prompt = payload.prompt { fields["prompt"] = String(prompt.prefix(500)) }
        if payload.event == "Stop" { fields["background"] = String(payload.backgroundTasks) }
        write("hook", fields)
    }

    /// What the window shows, as strings: a change in any of them is one `view` line.
    static func viewState(_ store: AppStore) -> [String: String] {
        let session = store.sessions.first { $0.id == store.selectedSessionId }
        return ["session": session.map { s in "\(s.id ?? 0) \(store.project(for: s)?.name ?? "?")" } ?? "none",
                "home": String(store.isHomeShown), "preset": store.shellPreset.rawValue,
                "settings": String(store.isSettingsShown), "whatChanged": String(store.isWhatChangedShown)]
    }

    /// The fields whose value differs, in a stable order.
    nonisolated static func changes(from old: [String: String], to new: [String: String]) -> [(String, String)] {
        new.keys.sorted().compactMap { key in old[key] == new[key] ? nil : (key, new[key] ?? "") }
    }

    /// Observation fires before the change lands: the new values are read on the next turn of the main loop.
    private static func observe(_ store: AppStore) {
        withObservationTracking { _ = viewState(store) } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let now = viewState(store)
                    for (field, value) in changes(from: last, to: now) { write("view", ["field": field, "value": value]) }
                    last = now
                    observe(store)
                }
            }
        }
    }

    private static func symbols(_ mods: NSEvent.ModifierFlags) -> String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { mods.contains($0.0) }.map(\.1).joined()
    }

    nonisolated static func line(_ kind: String, _ fields: [String: String], at date: Date = .now) -> String {
        var object = fields
        // Local time with its offset: the rhythm of a day reads in the user's hours.
        object["t"] = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current).format(date)
        object["kind"] = kind
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func write(_ kind: String, _ fields: [String: String]) {
        let data = Data((line(kind, fields) + "\n").utf8)
        queue.async { try? file?.write(contentsOf: data) }
    }
}
