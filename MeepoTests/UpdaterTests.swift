import XCTest
@testable import Meepo

final class UpdaterVersionTests: XCTestCase {
    private func v(_ tag: String) -> Updater.Version { Updater.Version(tag)! }

    func testSemverOrderWithPrereleases() {
        XCTAssertLessThan(v("v0.1.2-beta"), v("v0.1.3-beta"))
        XCTAssertLessThan(v("0.1.3-beta"), v("0.1.3"))                  // a release beats its own beta
        XCTAssertLessThan(v("0.9.3"), v("0.10.0"))                      // numbers, not text
        XCTAssertLessThan(v("0.2.0-beta.9"), v("0.2.0-beta.10"))
        XCTAssertLessThan(v("0.2.0-alpha"), v("0.2.0-beta"))
        XCTAssertEqual(v("v0.1.0"), v("0.1"))
        XCTAssertNil(Updater.Version("nightly"))
        XCTAssertTrue(v("v0.1.3-beta").isPrerelease)
    }

    private func release(_ tag: String, prerelease: Bool, draft: Bool = false, zip: Bool = true) -> Updater.Release {
        Updater.Release(tag_name: tag, prerelease: prerelease, draft: draft, html_url: "u/\(tag)", body: nil,
                        assets: zip ? [.init(name: "Meepo.zip", browser_download_url: "https://x/\(tag)/Meepo.zip")] : [])
    }

    func testPickFollowsTheChannel() {
        let releases = [release("v0.1.4-beta", prerelease: true), release("v0.1.3", prerelease: false),
                        release("v0.1.5-beta", prerelease: true, draft: true), release("v0.1.6", prerelease: false, zip: false)]
        XCTAssertEqual(Updater.pick(releases, channel: .beta, current: v("0.1.3-beta"))?.tag_name, "v0.1.4-beta")
        XCTAssertEqual(Updater.pick(releases, channel: .stable, current: v("0.1.3-beta"))?.tag_name, "v0.1.3")
        XCTAssertNil(Updater.pick(releases, channel: .stable, current: v("0.1.3")))      // nothing newer
        XCTAssertNil(Updater.pick(releases, channel: .beta, current: v("0.1.4-beta")))   // drafts and zip-less skipped
    }
}

final class UpdaterSafetyTests: XCTestCase {
    /// Only an app with the running copy's team and bundle id — and Apple's notarization — gets installed.
    func testVerifyAcceptsOurOwnBuildAndRejectsOthers() throws {
        let own = Bundle.main.bundleURL
        let signature = Updater.signature(of: own)
        let team = try XCTUnwrap(signature.team, "the test host is signed with the team's Developer ID")
        let bundleID = try XCTUnwrap(signature.identifier)

        XCTAssertNil(Updater.verify(own, team: team, bundleID: bundleID, requireNotarization: false))
        XCTAssertEqual(Updater.verify(own, team: team, bundleID: bundleID), "not notarized by Apple")   // a dev build
        XCTAssertNotNil(Updater.verify(own, team: "SOMEONEELSE", bundleID: bundleID, requireNotarization: false))
        XCTAssertNotNil(Updater.verify(URL(filePath: "/System/Applications/Calculator.app"), team: team, bundleID: bundleID,
                                       requireNotarization: false))
    }

    func testInstallSwapsAndKeepsTheOldOneAsBackup() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "upd-\(UUID().uuidString)")
        let target = tmp.appending(path: "Applications/Meepo.app"), staged = tmp.appending(path: "staged/Meepo.app")
        let backup = tmp.appending(path: "previous/Meepo.app")
        for (dir, text) in [(target, "old"), (staged, "new")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appending(path: "version"), atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(Updater.canReplace(target))
        try Updater.install(staged, over: target, backup: backup)
        XCTAssertEqual(try String(contentsOf: target.appending(path: "version"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: backup.appending(path: "version"), encoding: .utf8), "old")

        // A staged app that vanished: the running one is put back, never left missing.
        XCTAssertThrowsError(try Updater.install(tmp.appending(path: "gone/Meepo.app"), over: target, backup: backup))
        XCTAssertEqual(try String(contentsOf: target.appending(path: "version"), encoding: .utf8), "new")
    }
}

/// Against the real GitHub release (MEEPO_LIVE_UPDATE=1 only): download, unpack, and pass the full check.
final class UpdaterLiveTests: XCTestCase {
    func testRealReleaseDownloadsAndVerifies() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEEPO_LIVE_UPDATE"] == "1", "network test")
        let releases = try await Updater.fetchReleases()
        let release = try XCTUnwrap(releases.first { $0.tag_name == "v0.1.3-beta" })
        let app = try await Updater.download(release)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        XCTAssertNil(Updater.verify(app, team: "ZKXQWVLBRG", bundleID: "com.azamatfg.meepo"))   // notarized, ours
        XCTAssertNotNil(Updater.verify(app, team: "ZKXQWVLBRG", bundleID: "com.example.other"))
    }
}
