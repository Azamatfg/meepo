import Foundation

/// Meepo's own crash reports, as macOS writes them. Read locally, shown to the user, sent nowhere by Meepo.
enum CrashReports {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")

    /// The newest Meepo report written after `since`.
    static func latest(since: Date, in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("Meepo") && ["ips", "crash"].contains($0.pathExtension) }
            .compactMap { url in modified(url).map { (url, $0) } }
            .filter { $0.1 > since }
            .max { $0.1 < $1.1 }?.0
    }

    /// The report's text for the clipboard; very long ones are cut (GitHub issues take ~65K characters).
    static func text(of report: URL, limit: Int = 60_000) -> String {
        let text = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
        return text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
