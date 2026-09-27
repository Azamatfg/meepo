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

    func testTapModeKeepsEverythingElse() {
        var settings: [String: Any] = ["voice": ["enabled": true, "autoSubmit": true], "voiceEnabled": true, "model": "opus"]
        XCTAssertEqual(Voice.mode(settings), "hold", "Claude Code's default")
        Voice.setTap(in: &settings)
        XCTAssertEqual(Voice.mode(settings), "tap")
        XCTAssertTrue(Voice.isOn(settings))
        XCTAssertEqual((settings["voice"] as? [String: Any])?["autoSubmit"] as? Bool, true)
        XCTAssertEqual(settings["model"] as? String, "opus")
    }

    /// SPEAK on a hold-mode setup switches to tap first (one Space in hold mode would just type a space), then
    /// the same button is SEND; a request reaching claude ends the listening either way.
    @MainActor
    func testSpeakIsATapThatClaudeCodeUnderstands() async throws {
        let db = try DatabaseQueue()
        try AppDatabase.migrator.migrate(db)
        let home = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)")
        let bridge = BridgeInstaller(settingsURL: home.appending(path: "settings.json"), meepoHome: home)
        let store = AppStore(db: db, bridge: bridge, usageRoot: home, defaults: UserDefaults(suiteName: "meepo-tests-\(UUID().uuidString)")!)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"voice":{"enabled":true},"theme":"light"}"#.write(to: bridge.settingsURL, atomically: true, encoding: .utf8)
        try store.addProject(at: try makeTempRepo())
        try store.createSession(projectId: store.projects[0].id!, model: nil, prompt: nil)
        let id = store.sessions[0].id!

        store.speak(in: id)
        XCTAssertEqual(Voice.mode(try bridge.readSettings()), "tap")
        XCTAssertEqual(try bridge.readSettings()["theme"] as? String, "light")
        XCTAssertTrue(store.listeningSessionIds.contains(id), "SPEAK → listening, the button reads SEND")
        store.speak(in: id)
        XCTAssertFalse(store.listeningSessionIds.contains(id), "SEND → sent")

        store.speak(in: id)
        _ = store.handleHookEvent(HookPayload(event: "UserPromptSubmit", claudeSessionId: store.sessions[0].claudeSessionId), sessionId: id)
        XCTAssertFalse(store.listeningSessionIds.contains(id), "Space pressed by hand sent it: the button is SPEAK again")
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
