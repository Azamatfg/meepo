import AppKit

/// Tab-based session switching. Plain Tab / Shift+Tab stay with claude (completion, permission mode);
/// the sidebar handles them itself when it has focus. Cmd+N and Cmd+1..9 are menu commands in MeepoApp.
///
///   Option+Tab        next session
///   Option+Shift+Tab  previous session
///   Ctrl+Tab          next session waiting for the user
///   fn+Control (held) SPEAK in the open session while held, STOP on let go — the words stay in the prompt
@MainActor
final class HotkeyMonitor {
    private static let tabKeyCode: UInt16 = 48
    private static let returnKeyCode: UInt16 = 36
    private var monitor: Any?
    private var talkMonitor: Any?
    /// The session fn+Control is talking into, until it's let go — the open session may change meanwhile.
    private var talkingSessionId: Int64?

    init(store: AppStore) {
        // Local monitor sees keys before SwiftTerm, which would otherwise send Option+Tab as ESC+Tab.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
            // Demo story: Option+Return plays the ad's turns once the screen recording runs.
            if Demo.isStory, event.keyCode == Self.returnKeyCode, event.modifierFlags.contains(.option) {
                store?.startDemoStory()
                return nil
            }
            guard let store, event.keyCode == Self.tabKeyCode else { return event }
            let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
            switch mods {
            case .option: store.selectSession(offset: 1)
            case [.option, .shift]: store.selectSession(offset: -1)
            case .control: store.selectNextWaiting()
            default: return event
            }
            return nil
        }
        // Only modifiers: nothing is typed, the terminal still gets the event.
        talkMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self, weak store] event in
            guard let self, let store else { return event }
            let held = event.modifierFlags.intersection([.function, .control, .shift, .option, .command])
                == [.function, .control]
            if held, talkingSessionId == nil, store.isVoiceOn, !store.isHomeShown,
               let id = store.selectedSessionId, !store.listeningSessionIds.contains(id) {
                talkingSessionId = id
                store.speak(in: id)
            } else if !held, let id = talkingSessionId {
                talkingSessionId = nil
                // Already let go by itself (a question from Claude, the 3-minute limit): speak would start again.
                if store.listeningSessionIds.contains(id) { store.speak(in: id) }
            }
            return event
        }
    }
}
