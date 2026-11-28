import XCTest
@testable import Meepo

final class LocalBuildTests: XCTestCase {
    func testUpdateLinkWithABuildIsALocalBuild() throws {
        let url = try XCTUnwrap(URL(string: "meepo://update?build=/Users/me/.meepo/updates/local/Meepo.app&notes=fix%3A%20lag"))
        let build = try XCTUnwrap(AppStore.localBuild(in: url))
        XCTAssertEqual(build.app.path, "/Users/me/.meepo/updates/local/Meepo.app")
        XCTAssertEqual(build.notes, "fix: lag")
    }

    func testPlainUpdateLinkLooksForAReleaseInstead() throws {
        XCTAssertNil(AppStore.localBuild(in: try XCTUnwrap(URL(string: "meepo://update"))))
        XCTAssertNil(AppStore.localBuild(in: try XCTUnwrap(URL(string: "meepo://open?build=/x/Meepo.app"))))
    }
}

final class RegisteredCopiesTests: XCTestCase {
    func testOnlyMeepoAppPathsAreRead() {
        let dump = """
        path:                       /Users/me/Applications/Meepo.app (0x1a2b)
        name:                       Meepo
        path:                       /Users/me/meepo/.build/check/Build/Products/Debug/Meepo.app (0x3c4d)
        path:                       /Users/me/Library/Application Support/Figma/FigmaAgent.app (0x5e6f)
        path:                       /Users/me/Applications/Meepo.app (0x7a8b)
        path:                       /Users/me/Applications/Meepo.app/Contents/PlugIns/MeepoWidget.appex (0x9c0d)
        """
        XCTAssertEqual(Updater.registeredCopies(inDump: dump),
                       ["/Users/me/Applications/Meepo.app", "/Users/me/meepo/.build/check/Build/Products/Debug/Meepo.app"])
    }
}
