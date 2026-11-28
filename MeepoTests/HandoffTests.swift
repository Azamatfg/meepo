import XCTest
@testable import Meepo

/// Handoff as a file (2026-11-29): /meepo:handoff writes it and names it last; the next session reads the file.
/// A dropped video goes to /meepo:video, which watches it in a side context.
final class HandoffTests: XCTestCase {
    func testTheHandoffFileIsTheLastHandoffLine() {
        let reply = "Записал передачу.\n\nHANDOFF: /Users/me/.meepo/handoffs/taxi/2026-11-29-1410-sip-stats.md\n"
        XCTAssertEqual(AppStore.handoffPath(in: reply), "/Users/me/.meepo/handoffs/taxi/2026-11-29-1410-sip-stats.md")
        XCTAssertNil(AppStore.handoffPath(in: "Summary: did things"), "a plain summary: the old relay text")
        XCTAssertNil(AppStore.handoffPath(in: "HANDOFF: relative/path.md"), "only an absolute path")
    }

    func testVideosAreToldFromOtherFiles() {
        for name in ["bug.mov", "Screen Recording 2026.MP4", "a.webm", "b.m4v"] { XCTAssertTrue(Drops.isVideo(URL(filePath: "/x/\(name)")), name) }
        for name in ["shot.png", "notes.md", "movie"] { XCTAssertFalse(Drops.isVideo(URL(filePath: "/x/\(name)")), name) }
    }
}
