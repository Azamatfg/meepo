import XCTest
@testable import Meepo

/// The crash of 2026-09-25: git run from a SwiftUI body waited with waitUntilExit(), which spins the main run
/// loop, so AppKit began a display cycle inside the body update. Waiting must not run the loop.
@MainActor
final class ProcessWaitTests: XCTestCase {
    func testWaitingDoesNotRunTheMainRunLoop() throws {
        var ranDuringWait = false
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in ranDuringWait = true }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.2; exit 3"]
        try process.run()
        process.waitForExit()
        XCTAssertFalse(ranDuringWait, "nothing on the main run loop may run while we wait")
        XCTAssertEqual(process.terminationStatus, 3)
    }
}
