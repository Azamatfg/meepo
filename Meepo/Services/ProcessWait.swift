import Foundation

extension Process {
    /// Waits for the process to end by sleeping the thread. `waitUntilExit()` instead runs the calling thread's
    /// run loop until then; on the main thread that let AppKit start a display cycle inside a SwiftUI body
    /// update, and Meepo crashed opening New Session (2026-09-25). Foundation reaps the child on its own queue,
    /// so `isRunning` turns false without the main run loop.
    func waitForExit() {
        while isRunning { usleep(1_000) }
    }
}
