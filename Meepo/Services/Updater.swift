import Foundation

/// Self-update the way Claude Code does it (user decision 2026-09-25): check at launch and every few hours,
/// download in the background, install when Meepo quits (or on RESTART NOW). A download is installed only if
/// it carries the same Developer ID team and bundle id as the running app and Apple notarized it.
enum Updater {
    static let releasesURL = URL(string: "https://api.github.com/repos/Azamatfg/meepo/releases?per_page=20")!
    static var stagingDir: URL { MeepoHome.url.appending(path: "updates") }

    enum Channel: String, CaseIterable { case beta, stable }

    /// A release tag as a comparable version: v0.1.3-beta.2 → [0,1,3] + prerelease ["beta", "2"].
    struct Version: Comparable, CustomStringConvertible {
        let numbers: [Int]
        let prerelease: [String]
        let text: String

        init?(_ tag: String) {
            let text = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let parts = text.split(separator: "-", maxSplits: 1)
            guard let core = parts.first else { return nil }
            let numbers = core.split(separator: ".").map { Int($0) }
            guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
            self.numbers = numbers.compactMap { $0 }
            self.prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
            self.text = text
        }

        var description: String { text }
        var isPrerelease: Bool { !prerelease.isEmpty }

        /// Semver order: numbers first, then a release beats its own prereleases (0.1.3 > 0.1.3-beta).
        static func < (a: Version, b: Version) -> Bool {
            for i in 0..<max(a.numbers.count, b.numbers.count) {
                let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
                if x != y { return x < y }
            }
            if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
            for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
                if let i = Int(x), let j = Int(y) { return i < j }
                return x < y
            }
            return a.prerelease.count < b.prerelease.count
        }

        static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
    }

    struct Release: Decodable, Equatable {
        struct Asset: Decodable, Equatable {
            let name: String
            let browser_download_url: String
        }

        let tag_name: String
        let prerelease: Bool
        let draft: Bool
        let html_url: String
        let body: String?
        let assets: [Asset]

        var version: Version? { Version(tag_name) }
        var zip: URL? { assets.first { $0.name == "Meepo.zip" }.flatMap { URL(string: $0.browser_download_url) } }
    }

    /// The build's own tag, stamped by the release workflow (MeepoReleaseTag); nil for local builds.
    static var currentVersion: Version? {
        (Bundle.main.object(forInfoDictionaryKey: "MeepoReleaseTag") as? String).flatMap { $0.isEmpty ? nil : Version($0) }
    }

    /// The newest release worth installing: on the stable channel prereleases don't count.
    static func pick(_ releases: [Release], channel: Channel, current: Version) -> Release? {
        releases
            .filter { !$0.draft && $0.zip != nil && (channel == .beta || !$0.prerelease) }
            .compactMap { release in release.version.map { (release, $0) } }
            .filter { $0.1 > current }
            .max { $0.1 < $1.1 }?.0
    }

    static func fetchReleases() async throws -> [Release] {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("GitHub didn't answer") }
        return try JSONDecoder().decode([Release].self, from: data)
    }

    /// Downloads and unpacks the release next to the others in ~/.meepo/updates; returns the unpacked app.
    static func download(_ release: Release) async throws -> URL {
        guard let zip = release.zip else { throw Failure("No Meepo.zip in \(release.tag_name)") }
        let (file, _) = try await URLSession.shared.download(from: zip)
        let folder = stagingDir.appending(path: release.tag_name)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", file.path, folder.path]).status == 0 else { throw Failure("Couldn't unpack the update") }
        try? FileManager.default.removeItem(at: file)
        let app = folder.appending(path: "Meepo.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw Failure("The update has no Meepo.app") }
        return app
    }

    /// nil = safe to install: intact signature, the running app's team and bundle id, notarized by Apple.
    static func verify(_ app: URL, team: String, bundleID: String, requireNotarization: Bool = true) -> String? {
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else { return "broken signature" }
        let info = signature(of: app)
        guard info.team == team else { return "signed by \(info.team ?? "nobody"), not \(team)" }
        guard info.identifier == bundleID else { return "a different app (\(info.identifier ?? "?"))" }
        if requireNotarization {
            let gatekeeper = run("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", app.path])
            guard gatekeeper.status == 0, gatekeeper.output.contains("Notarized Developer ID") else { return "not notarized by Apple" }
        }
        return nil
    }

    /// TeamIdentifier and Identifier from `codesign -dv`.
    static func signature(of app: URL) -> (team: String?, identifier: String?) {
        let out = run("/usr/bin/codesign", ["-dv", app.path]).output
        func field(_ name: String) -> String? {
            out.split(separator: "\n").first { $0.hasPrefix("\(name)=") }.map { String($0.dropFirst(name.count + 1)) }
                .flatMap { $0 == "not set" ? nil : $0 }
        }
        return (field("TeamIdentifier"), field("Identifier"))
    }

    /// Where the running app lives can be replaced by this user (Homebrew and drag-installs usually can).
    static func canReplace(_ target: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: target.path)
    }

    /// The swap, at quit: the running app becomes the backup, the staged one takes its place.
    static func install(_ staged: URL, over target: URL, backup: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: backup)
        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: target, to: backup)
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            try? fm.moveItem(at: backup, to: target) // put the old one back rather than leave nothing
            throw error
        }
    }

    /// Opens the app again once this process is gone (RESTART NOW).
    static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? process.run()
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    @discardableResult
    private static func run(_ executable: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe                              // codesign and spctl answer on stderr
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
