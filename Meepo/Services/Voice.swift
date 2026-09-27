import AppKit
import AVFoundation

/// Claude Code's voice dictation (/voice). meepo turns it on the way /voice does — in ~/.claude/settings.json, so it
/// holds in every session — and never types /voice into a terminal: without an argument /voice is a switch, and
/// would turn voice off for someone who already has it on. SPEAK holds Space for you in Claude Code's "hold" mode
/// (checked in 2.1.283): 5 Spaces in a row start listening, a gap over 120 ms is the key let go — the words land in
/// the prompt unsent, to fix or add to; two Spaces within 300 ms right after would send, so a non-Space key goes first.
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

    /// Hold to talk, Claude Code's default: what SPEAK needs. Every other setting stays as it is.
    static func setHold(in settings: inout [String: Any]) {
        var voice = settings["voice"] as? [String: Any] ?? [:]
        voice["mode"] = "hold"
        settings["voice"] = voice
    }

    /// The push-to-talk key, repeated while SPEAK holds it — as the keyboard's own key repeat does.
    static let holdKey = " "
    /// Well under Claude Code's 120 ms "let go" gap.
    static let holdRepeat: Duration = .milliseconds(40)
    /// A gap this long since the last Space and Claude Code may have let go already (it does past 120 ms).
    static let letGo: Duration = .milliseconds(100)
    /// SPEAK left on by mistake lets go by itself.
    static let holdLimit: Duration = .seconds(180)
    /// Right arrow: a key that isn't Space, so the Spaces that follow don't count as a double tap that sends
    /// what's already there. At the end of the prompt it moves nothing.
    static let beforeHold = "\u{1b}[C"

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
