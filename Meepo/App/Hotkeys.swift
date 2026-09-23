import AppKit

/// Tab-based session switching. Plain Tab / Shift+Tab stay with claude (completion, permission mode);
/// the sidebar handles them itself when it has focus. Cmd+N and Cmd+1..9 are menu commands in MeepoApp.
///
///   Option+Tab        next session
///   Option+Shift+Tab  previous session
///   Ctrl+Tab          next session waiting for the user
@MainActor
final class HotkeyMonitor {
    private static let tabKeyCode: UInt16 = 48
    private var monitor: Any?

    init(store: AppStore) {
        // Local monitor sees keys before SwiftTerm, which would otherwise send Option+Tab as ESC+Tab.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
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
    }
}
