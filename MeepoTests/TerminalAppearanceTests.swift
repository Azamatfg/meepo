import AppKit
import XCTest
@testable import Meepo

@MainActor
final class TerminalAppearanceTests: XCTestCase {
    /// Switching the app light ↔ dark repaints terminals already open: SwiftTerm keeps the color it was given.
    func testOpenTerminalRepaintsWhenTheAppTurnsDark() async throws {
        let app = try XCTUnwrap(NSApp)
        let saved = app.appearance
        defer { app.appearance = saved }
        app.appearance = NSAppearance(named: .aqua)
        let terminals = TerminalRegistry()
        terminals.showText("x", for: 1)
        terminals.observeAppearance()
        var turnedDark: Bool?
        terminals.onAppearanceChange = { turnedDark = $0 }
        let light = try XCTUnwrap(terminals.view(for: 1)?.nativeBackgroundColor.usingColorSpace(.sRGB))

        app.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(200))
        let dark = try XCTUnwrap(terminals.view(for: 1)?.nativeBackgroundColor.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(light.brightnessComponent, 0.8)
        XCTAssertLessThan(dark.brightnessComponent, 0.2)
        XCTAssertEqual(turnedDark, true)
    }
}
