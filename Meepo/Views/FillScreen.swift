import AppKit
import SwiftUI

/// The main window opens in macOS full screen (as the green button does: its own Space, no menu bar or Dock) —
/// once per launch, so leaving it afterwards stays left (2026-11-28: the user wants meepo full screen from the start).
struct FillScreenOnLaunch: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Filler() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Filler: NSView {
        @MainActor static var isDone = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !Self.isDone, let window else { return }
            Self.isDone = true
            // After SwiftUI has set up the window, or the toggle is lost; skipped if macOS restored full screen itself.
            DispatchQueue.main.async {
                window.collectionBehavior.insert(.fullScreenPrimary)
                if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            }
        }
    }
}
