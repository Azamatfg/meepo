import AppKit
import AVFoundation

/// Claude Code's voice dictation (/voice). meepo turns it on the way /voice does — in ~/.claude/settings.json, so it
/// holds in every session — and never types /voice into a terminal: without an argument /voice is a switch, and
/// would turn voice off for someone who already has it on. meepo uses Claude Code's "tap" mode (checked in 2.1.283):
/// with an empty prompt one Space starts listening, the next stops and sends — so a button can press it for you.
enum Voice {
    /// Claude Code's own rule (2.1.283): `voice.enabled` when it's there, else `voiceEnabled` — not either of them.
    static func isOn(_ settings: [String: Any]) -> Bool {
        ((settings["voice"] as? [String: Any])?["enabled"] as? Bool ?? settings["voiceEnabled"] as? Bool) == true
    }

    /// What /voice writes: both keys. The mode (hold or tap) and every other setting stay as they are.
    static func set(_ on: Bool, in settings: inout [String: Any]) {
        var voice = settings["voice"] as? [String: Any] ?? [:]
        voice["enabled"] = on
        settings["voice"] = voice
        settings["voiceEnabled"] = on
    }

    /// "hold" (Claude Code's default) or "tap".
    static func mode(_ settings: [String: Any]) -> String {
        (settings["voice"] as? [String: Any])?["mode"] as? String ?? "hold"
    }

    /// Tap to start, tap to stop and send — what SPEAK/SEND press. Every other setting stays as it is.
    static func setTap(in settings: inout [String: Any]) {
        var voice = settings["voice"] as? [String: Any] ?? [:]
        voice["mode"] = "tap"
        settings["voice"] = voice
    }

    /// What SPEAK and SEND type: the push-to-talk key, Space. In tap mode an empty prompt takes it as a tap.
    static let tap = " "

    /// Voice needs a Claude.ai sign-in (`claude auth status` → authMethod): an API key, a key helper or a cloud
    /// provider can't use it. nil — couldn't tell — hides it too.
    static func isAvailable(authMethod: String?) -> Bool {
        guard let authMethod else { return false }
        return !["none", "api_key", "api_key_helper", "third_party"].contains(authMethod)
    }

    enum Microphone { case notAsked, allowed, denied }

    /// Claude Code runs inside meepo's terminals, so macOS asks meepo for the microphone, not claude.
    static var microphone: Microphone {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notAsked
        case .authorized: .allowed
        default: .denied
        }
    }

    /// macOS's own question, on the user's click — never at launch.
    static func askForMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
