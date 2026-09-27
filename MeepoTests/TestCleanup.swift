import Foundation
import XCTest

/// The test bundle's principal class: when a run ends, removes the settings suites tests made for themselves
/// (`UserDefaults(suiteName: "meepo-tests-<UUID>")` and the like) — otherwise every run leaves hundreds of files in
/// ~/Library/Preferences. Only names ending in a UUID go; the app's own com.azamatfg.meepo is never one.
final class TestCleanup: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
        for suite in Self.testSuites(in: (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []) {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder.appending(path: suite + ".plist"))
        }
    }

    /// "meepo-tests-<UUID>.plist" → "meepo-tests-<UUID>"; anything else is left alone.
    static func testSuites(in files: [String]) -> [String] {
        files.compactMap { file in
            guard file.hasSuffix(".plist") else { return nil }
            let suite = String(file.dropLast(6))
            return suite.wholeMatch(of: #/meepo-[a-z0-9]+-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/#) != nil ? suite : nil
        }
    }
}

final class TestCleanupTests: XCTestCase {
    func testOnlySuitesTestsMadeGo() {
        XCTAssertEqual(TestCleanup.testSuites(in: [
            "meepo-tests-0D4C9F2A-1B2C-4D5E-8F90-A1B2C3D4E5F6.plist",
            "meepo-snap-0d4c9f2a-1b2c-4d5e-8f90-a1b2c3d4e5f6.plist",
            "com.azamatfg.meepo.plist",
            "com.azamatfg.meepo.demo.plist",
            "meepo-tests-notauuid.plist",
            "meepo-tests-0D4C9F2A-1B2C-4D5E-8F90-A1B2C3D4E5F6.lockfile",
        ]), ["meepo-tests-0D4C9F2A-1B2C-4D5E-8F90-A1B2C3D4E5F6", "meepo-snap-0d4c9f2a-1b2c-4d5e-8f90-a1b2c3d4e5f6"])
    }
}
