import Foundation

/// What the desktop widget shows (SPEC module 13). Meepo writes it into the shared App Group container;
/// the sandboxed widget can't read ~/.meepo, only this file.
struct WidgetSnapshot: Codable, Equatable {
    var tokensToday = 0
    var activeSessions = 0
    var waitingSessions = 0
    var updatedAt = Date.distantPast

    static let appGroup = "ZKXQWVLBRG.com.azamatfg.meepo"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "widget.json")
    }

    static func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func write() throws {
        guard let url = Self.fileURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
