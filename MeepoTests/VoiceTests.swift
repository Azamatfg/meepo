import GRDB
import XCTest
@testable import Meepo

/// VOICE writes ~/.claude/settings.json the way Claude Code's /voice does (2.1.283) — here on a temp copy.
final class VoiceTests: XCTestCase {
    func testVoiceEnabledWinsOverTheOldKeyNotEither() {
        XCTAssertFalse(Voice.isOn(["voiceEnabled": true, "voice": ["enabled": false]]), "voice.enabled first, not ||")
        XCTAssertTrue(Voice.isOn(["voiceEnabled": false, "voice": ["enabled": true]]))
        XCTAssertTrue(Voice.isOn(["voiceEnabled": true]), "the old key alone still counts")
        XCTAssertTrue(Voice.isOn(["voiceEnabled": true, "voice": ["mode": "tap"]]), "voice without enabled falls back")
        XCTAssertFalse(Voice.isOn([:]))
    }

    func testTurningItOnKeepsTheModeAndEverythingElse() throws {
        var settings: [String: Any] = ["voice": ["mode": "tap"], "language": "russian",
                                       "hooks": ["Stop": [["hooks": [["type": "command", "command": "x.sh"]]]]]]
        Voice.set(true, in: &settings)
        XCTAssertTrue(Voice.isOn(settings))
        XCTAssertEqual(settings["voiceEnabled"] as? Bool, true)
        XCTAssertEqual((settings["voice"] as? [String: Any])?["mode"] as? String, "tap", "hold or tap is the user's")
        XCTAssertEqual(settings["language"] as? String, "russian")
        XCTAssertNotNil(settings["hooks"])
        Voice.set(false, in: &settings)
        XCTAssertFalse(Voice.isOn(settings))
        XCTAssertEqual((settings["voice"] as? [String: Any])?["mode"] as? String, "tap")
    }

    func testOnlyAClaudeAiSignInGetsTheButton() {
        XCTAssertTrue(Voice.isAvailable(authMethod: "claude.ai"))
        XCTAssertTrue(Voice.isAvailable(authMethod: "oauth_token"))
        for method in ["none", "api_key", "api_key_helper", "third_party"] {
            XCTAssertFalse(Voice.isAvailable(authMethod: method), method)
        }
        XCTAssertFalse(Voice.isAvailable(authMethod: nil), "couldn't tell: no button")
    }

    func testAuthStatusCarriesHowClaudeIsSignedIn() throws {
        let status = try XCTUnwrap(ClaudeLauncher.AuthStatus(json: Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}"#.utf8)))
        XCTAssertEqual(status, ClaudeLauncher.AuthStatus(loggedIn: true, method: "claude.ai"))
        XCTAssertNil(ClaudeLauncher.AuthStatus(json: Data("Not logged in".utf8)))
    }

    /// /voice typed in a session since the last read: VOICE flips what's in the settings now, not a stale state.
    @MainActor
    func testToggleReadsTheSettingsFirst() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let home = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)")
        let bridge = BridgeInstaller(settingsURL: home.appending(path: "settings.json"), meepoHome: home)
        let store = AppStore(db: db, bridge: bridge, usageRoot: home, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        XCTAssertFalse(store.isVoiceOn)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"voiceEnabled":true}"#.write(to: bridge.settingsURL, atomically: true, encoding: .utf8)
        _ = await store.toggleVoice()
        XCTAssertFalse(store.isVoiceOn)
        XCTAssertFalse(Voice.isOn(try bridge.readSettings()), "turned off: it was on when clicked")
    }

    func testHoldModeKeepsEverythingElse() {
        var settings: [String: Any] = ["voice": ["enabled": true, "mode": "tap", "autoSubmit": true], "voiceEnabled": true, "model": "opus"]
        XCTAssertEqual(Voice.mode(settings), "tap")
        Voice.setHold(in: &settings)
        XCTAssertEqual(Voice.mode(settings), "hold")
        XCTAssertTrue(Voice.isOn(settings))
        XCTAssertEqual((settings["voice"] as? [String: Any])?["autoSubmit"] as? Bool, true)
        XCTAssertEqual(settings["model"] as? String, "opus")
    }

    /// Claude Code's hold-to-talk (2.1.283): 5 Spaces start it, a gap over 120 ms lets go. SPEAK repeats Space well
    /// inside that gap and starts with a non-Space key, so the first Spaces never count as a double tap that sends.
    func testSpeakHoldsSpaceTheWayTheKeyboardDoes() {
        XCTAssertEqual(Voice.holdKey, " ")
        XCTAssertLessThan(Voice.holdRepeat, .milliseconds(120))
        XCTAssertFalse(Voice.beforeHold.contains(" "))
    }

    /// SPEAK on a tap-mode setup switches to hold (tap mode sends on the second Space); SPEAK again is STOP;
    /// a request reaching claude ends the listening either way; while Claude asks something SPEAK waits.
    @MainActor
    func testSpeakHoldsAndStopLetsGo() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let home = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)")
        let bridge = BridgeInstaller(settingsURL: home.appending(path: "settings.json"), meepoHome: home)
        let store = AppStore(db: db, bridge: bridge, usageRoot: home, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"voice":{"enabled":true,"mode":"tap"},"theme":"light"}"#.write(to: bridge.settingsURL, atomically: true, encoding: .utf8)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        let session = store.sessions[0], id = session.id!

        store.speak(in: id)
        XCTAssertEqual(Voice.mode(try bridge.readSettings()), "hold")
        XCTAssertEqual(try bridge.readSettings()["theme"] as? String, "light")
        XCTAssertTrue(store.listeningSessionIds.contains(id), "SPEAK → listening, the button reads STOP")
        store.speak(in: id)
        XCTAssertFalse(store.listeningSessionIds.contains(id), "STOP → let go; the words stay in the prompt")

        store.speak(in: id)
        _ = store.handleHookEvent(HookPayload(event: "UserPromptSubmit", claudeSessionId: session.claudeSessionId), sessionId: id)
        XCTAssertFalse(store.listeningSessionIds.contains(id), "sent: the button is SPEAK again")

        _ = store.handleHookEvent(HookPayload(event: "PermissionRequest", claudeSessionId: session.claudeSessionId), sessionId: id)
        store.speak(in: id)
        XCTAssertFalse(store.listeningSessionIds.contains(id), "Claude asks something: Space could pick an answer")
    }

    /// A store with voice on and one session; what SPEAK types is recorded, not sent to a terminal.
    @MainActor
    private func listeningStore() throws -> (AppStore, Session, Keys) {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let home = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)")
        let bridge = BridgeInstaller(settingsURL: home.appending(path: "settings.json"), meepoHome: home)
        let store = AppStore(db: db, bridge: bridge, usageRoot: home, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"voice":{"enabled":true,"mode":"hold"}}"#.write(to: bridge.settingsURL, atomically: true, encoding: .utf8)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        let keys = Keys()
        store.keySink = { text, _ in keys.typed.append(text) }
        return (store, store.sessions[0], keys)
    }

    final class Keys { var typed: [String] = []; var spaces: Int { typed.filter { $0 == Voice.holdKey }.count } }

    /// Each way a hold ends stops the Spaces too — a loop typing on would start listening again, or send.
    @MainActor
    func testEveryWayAHoldEndsStopsTheSpaces() async throws {
        let (store, session, keys) = try listeningStore()
        let id = session.id!
        func ended(by end: () -> Void, _ what: String) async throws {
            store.speak(in: id)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertGreaterThan(keys.spaces, 0, what)
            end()
            XCTAssertFalse(store.listeningSessionIds.contains(id), what)
            try await Task.sleep(for: .milliseconds(100))
            let after = keys.spaces
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(keys.spaces, after, "no Space after: \(what)")
            keys.typed = []
        }
        try await ended(by: { store.speak(in: id) }, "STOP")
        try await ended(by: { store.restartSession(id) }, "restart")
        try await ended(by: { _ = store.handleHookEvent(HookPayload(event: "UserPromptSubmit", claudeSessionId: session.claudeSessionId), sessionId: id) }, "sent")
        try await ended(by: { store.sessionExited(id) }, "claude exited")
        store.speak(in: id)
        XCTAssertTrue(keys.typed.isEmpty, "an exited session isn't listened to")
    }

    /// A PermissionRequest or AskUserQuestion arriving mid-hold: a Space from then on could pick an answer.
    @MainActor
    func testAQuestionMidHoldStopsTheSpaces() async throws {
        let (store, session, keys) = try listeningStore()
        let id = session.id!
        store.speak(in: id)
        try await Task.sleep(for: .milliseconds(150))
        _ = store.handleHookEvent(HookPayload(event: "PermissionRequest", claudeSessionId: session.claudeSessionId), sessionId: id)
        try await Task.sleep(for: .milliseconds(100))
        let after = keys.spaces
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(keys.spaces, after)
        XCTAssertFalse(store.listeningSessionIds.contains(id), "the button reads SPEAK again")
    }

    /// meepo busy for longer than Claude Code's 120 ms let-go gap: the key counts as let go there, so the next two
    /// Spaces would be a double tap that sends. The hold ends instead.
    @MainActor
    func testAStallLetsGoInsteadOfSending() async throws {
        let (store, session, keys) = try listeningStore()
        let id = session.id!
        store.keySink = { text, _ in
            keys.typed.append(text)
            if keys.spaces == 3 { usleep(150_000) } // the main thread stalls right after a Space
        }
        store.speak(in: id)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(keys.spaces, 3, "no Space after the stall")
        XCTAssertFalse(store.listeningSessionIds.contains(id))
    }

    /// STOP → SPEAK faster than a Space: the first loop quits, only one holds the key.
    @MainActor
    func testQuickStopSpeakRunsOneLoop() async throws {
        let (store, session, keys) = try listeningStore()
        let id = session.id!
        store.speak(in: id)
        store.speak(in: id)
        store.speak(in: id)
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertTrue(store.listeningSessionIds.contains(id))
        XCTAssertLessThanOrEqual(keys.spaces, 13, "one Space per 40 ms, not two") // two loops: ~20
        store.speak(in: id)
    }

    /// SEND is off while listening: Claude Code puts the words in a moment after the let-go, so an Enter right away
    /// would send the prompt without them.
    @MainActor
    func testSendWaitsForStop() async throws {
        let (store, session, keys) = try listeningStore()
        let id = session.id!
        store.speak(in: id)
        store.sendSpoken(in: id)
        XCTAssertFalse(keys.typed.contains("\r"))
        store.speak(in: id)
        store.sendSpoken(in: id)
        XCTAssertEqual(keys.typed.last, "\r")
    }

    /// One edit, one line in Tools → Changes — it used to log a second, "Hook bridge", for every settings edit.
    func testASettingsEditIsLoggedOnceUnderItsOwnName() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)")
        let bridge = BridgeInstaller(settingsURL: home.appending(path: "settings.json"), meepoHome: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"voice":{"mode":"tap"}}"#.write(to: bridge.settingsURL, atomically: true, encoding: .utf8)
        try bridge.editSettings("Voice on (/voice)") { Voice.set(true, in: &$0) }
        XCTAssertTrue(Voice.isOn(try bridge.readSettings()))
        XCTAssertEqual(ChangeLog.entries(backups: home.appending(path: "backups")).map(\.action), ["Voice on (/voice)"])
        try bridge.install()
        XCTAssertEqual(ChangeLog.entries(backups: home.appending(path: "backups")).first?.action, "Hook bridge")
    }
}

/// A button's command ends in Enter; while Claude asks something, that Enter would pick an answer for the user.
@MainActor
final class TypingTests: XCTestCase {
    func testEnterWaitsWhileClaudeAsks() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let home = FileManager.default.temporaryDirectory.appending(path: "typing-\(UUID().uuidString)")
        let store = AppStore(db: db, bridge: BridgeInstaller(settingsURL: home.appending(path: "s.json"), meepoHome: home),
                             usageRoot: home, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        let session = store.sessions[0], id = session.id!

        XCTAssertTrue(store.type("/qa\r", into: id), "nothing asked: the button works")
        _ = store.handleHookEvent(HookPayload(event: "PermissionRequest", claudeSessionId: session.claudeSessionId), sessionId: id)
        XCTAssertFalse(store.type("/qa\r", into: id), "a permission is open: Enter would answer it")
        XCTAssertNotNil(store.confirmation?.alternative, "says why, and lets the user send anyway")
        XCTAssertTrue(store.type(" ", into: id), "no Enter: type() lets it through (SPEAK checks for itself)")
        _ = store.handleHookEvent(HookPayload(event: "Stop", claudeSessionId: session.claudeSessionId), sessionId: id)
        XCTAssertTrue(store.type("/qa\r", into: id), "answered and done: the button works again")
    }
}
