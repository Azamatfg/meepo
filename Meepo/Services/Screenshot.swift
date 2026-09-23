import AppKit
import Carbon.HIToolbox
import SwiftUI

/// System-wide hotkey via Carbon `RegisterEventHotKey`: works without the Accessibility permission
/// that a global keyboard monitor would need.
@MainActor
final class GlobalHotKey {
    struct Combo: Hashable, Identifiable {
        let title: String
        let keyCode: UInt32
        let modifiers: UInt32
        var id: String { title }
    }

    /// Choices in Settings; ⌘⇧6 is free on Macs without a Touch Bar.
    static let combos = [
        Combo(title: "⌘⇧6", keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(cmdKey | shiftKey)),
        Combo(title: "⌃⌥⌘S", keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey | cmdKey)),
        Combo(title: "⌥⇧S", keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | shiftKey)),
    ]

    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextId: UInt32 = 1
    private static var isHandlerInstalled = false
    private var ref: EventHotKeyRef?
    private let id: UInt32
    /// noErr when the system accepted the combo; otherwise another app or macOS owns it.
    let status: OSStatus

    init(_ combo: Combo, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextId
        Self.nextId += 1
        Self.actions[id] = action
        // The dispatcher target (not the application target) receives hotkeys reliably in a Cocoa app.
        status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: 0x4D45_4550 /* MEEP */, id: id),
                                     GetEventDispatcherTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard !isHandlerInstalled else { return }
        isHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            MainActor.assumeIsolated { GlobalHotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Hotkey → area selection → pick a session → the image lands in it as an attachment (SPEC module 8).
/// Uses the system `screencapture`; the temp file is deleted right after, nothing stays on the Desktop.
@MainActor
final class ScreenshotFlow {
    private let store: AppStore
    private var panel: NSPanel?
    private var isCapturing = false
    static let shotsDir = MeepoHome.url.appending(path: "shots")
    private static let explainedKey = "screenshotPermissionExplained"

    init(store: AppStore) {
        self.store = store
        Self.removeOldShots()
    }

    func start() {
        guard !isCapturing, panel == nil else { return }
        guard explainPermissionOnce() else { return }
        isCapturing = true
        let previous = NSWorkspace.shared.frontmostApplication
        let file = Self.shotsDir.appending(path: "\(UUID().uuidString).png")
        try? FileManager.default.createDirectory(at: Self.shotsDir, withIntermediateDirectories: true)
        Task {
            // -i interactive area/window selection, -x no sound; Esc leaves no file.
            await Task.detached {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", file.path]
                try? process.run()
                process.waitUntilExit()
            }.value
            isCapturing = false
            guard let image = NSImage(contentsOf: file) else { return }
            showPicker(image: image, file: file, returnTo: previous)
        }
    }

    private func showPicker(image: NSImage, file: URL, returnTo previous: NSRunningApplication?) {
        let choices = store.orderedSessions.filter { store.runningSessionIds.contains($0.id ?? -1) }.map { session in
            (id: session.id!, title: [store.project(for: session)?.name, session.branch].compactMap { $0 }.joined(separator: " · "))
        }
        let finish = { [weak self] (target: Int64?) in
            guard let self else { return }
            if let target { self.deliver(image, to: target) }
            try? FileManager.default.removeItem(at: file)
            self.panel?.close()
            self.panel = nil
            // Back to where the user was, unless that was Meepo itself.
            if let previous, previous != NSRunningApplication.current { previous.activate() }
        }
        let initial = choices.firstIndex { $0.id == store.selectedSessionId } ?? 0
        let view = ShotPicker(image: image, choices: choices, index: initial, onFinish: finish)
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: view.environment(store))
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Claude Code pastes images with Ctrl+V: put the shot on the clipboard and press it in that terminal.
    private func deliver(_ image: NSImage, to sessionId: Int64) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        store.type("\u{16}", into: sessionId)
    }

    /// macOS asks for Screen Recording the first time; say why before it does (SPEC module 8).
    private func explainPermissionOnce() -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.explainedKey) else { return true }
        let alert = NSAlert()
        alert.messageText = "Screenshots to sessions"
        alert.informativeText = """
            Meepo uses the system screenshot tool: select an area, pick a session, and the image is pasted into it. \
            No files are kept.

            macOS may ask to allow Meepo under Privacy & Security → Screen Recording. Without it, shots show \
            only the desktop background.
            """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: Self.explainedKey)
        return true
    }

    /// Leftovers from a crash or quit mid-pick: nothing older than an hour stays.
    static func removeOldShots(olderThan age: TimeInterval = 3600, in dir: URL = shotsDir, now: Date = .now) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// A borderless panel still needs to take keys for ↑↓/Tab/Enter/Esc.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ShotPicker: View {
    let image: NSImage
    let choices: [(id: Int64, title: String)]
    @State var index: Int
    let onFinish: (Int64?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 180)
                .pixelFrame(4)
            Text("SEND TO").font(Fonts.title(16)).foregroundStyle(Tokens.text)
            if choices.isEmpty {
                Text("No running sessions").foregroundStyle(Tokens.textDim)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { i, choice in
                        Text(choice.title)
                            .font(Fonts.mono(13))
                            .foregroundStyle(Tokens.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(i == index ? Tokens.dirt : .clear)
                            .overlay { if i == index { Rectangle().stroke(Tokens.selection, lineWidth: 2) } }
                            .contentShape(Rectangle())
                            .onTapGesture { onFinish(choice.id) }
                    }
                }
            }
            Text("↑↓ / Tab · Enter to send · Esc to cancel").font(.caption).foregroundStyle(Tokens.textDim)
        }
        .padding(12)
        .frame(width: 420, height: 440)
        .background(Tokens.grass)
        .pixelFrame(6)
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(keys: [.tab]) { press in move(press.modifiers.contains(.shift) ? -1 : 1) }
        .onKeyPress(.return) {
            onFinish(choices.indices.contains(index) ? choices[index].id : nil)
            return .handled
        }
        .onKeyPress(.escape) {
            onFinish(nil)
            return .handled
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !choices.isEmpty else { return .handled }
        index = (index + step + choices.count) % choices.count
        return .handled
    }
}
