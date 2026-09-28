import Foundation

/// Every change Meepo makes to the user's files (SPEC §8), one JSON line in `<backups>/changes.jsonl`
/// next to the backup that undoes it. Restoring is itself logged, so it can be undone too.
enum ChangeLog {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var date = Date.now
        let action: String
        let file: String
        /// The file as it was before; nil = Meepo created it, so undoing moves it to the Trash.
        let backup: String?
    }

    static func url(in backups: URL) -> URL { backups.appending(path: "changes.jsonl") }

    /// Call right after the change, with the backup the caller made first.
    static func record(_ action: String, file: URL, backup: URL?, backups: URL) {
        let entry = Entry(action: action, file: file.path, backup: backup?.path)
        guard let data = try? encoder.encode(entry) else { return }
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let log = url(in: backups)
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: log)
        }
    }

    /// Newest first; unreadable lines are skipped.
    static func entries(backups: URL) -> [Entry] {
        guard let text = try? String(contentsOf: url(in: backups), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }.reversed()
    }

    /// A copy of `file` in `backups/<folder>/`, for callers that had no backup of their own.
    static func backup(_ file: URL, folder: String, backups: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let copy = backups.appending(path: "\(folder)/\(file.lastPathComponent)-\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    /// Puts the file back as it was before `entry`; the current state is backed up first. A file or folder Meepo
    /// created goes to the Trash instead (a copied folder can be big) — that is its backup. Blocking: a backup
    /// copies whole folders, so call off the main thread.
    static func restore(_ entry: Entry, backups: URL) throws {
        let fm = FileManager.default
        let file = URL(filePath: entry.file)
        if entry.backup == nil {
            var trashed: NSURL?
            if fm.fileExists(atPath: file.path) { try fm.trashItem(at: file, resultingItemURL: &trashed) }
            record("Restore: \(entry.action)", file: file, backup: trashed as URL?, backups: backups)
            return
        }
        // A backup that's gone (the Trash emptied) must fail before the current file is taken away.
        guard let saved = entry.backup.map({ URL(filePath: $0) }), fm.fileExists(atPath: saved.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: entry.backup ?? entry.file])
        }
        let current = try backup(file, folder: "restored", backups: backups)
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: saved, to: file)
        record("Restore: \(entry.action)", file: file, backup: current, backups: backups)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
