import Foundation
import GRDB

/// How meepo itself is used (Settings → Learn from how I use meepo): a name — "panel.explorer", "stage.qa",
/// "preset.focus" — and how many times a day. No text, no content; nothing leaves this Mac. Automations reads it
/// for what history can't show: the parts of the layout and the bar that go unused.
enum UsageCounts {
    /// Counted this long, and not once in it: worth asking about.
    static let quietDays = 14

    static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).timeZone(separator: .omitted))
    }

    static func add(_ name: String, on date: Date = .now, in db: some DatabaseWriter) {
        try? db.write { db in
            try db.execute(sql: """
                INSERT INTO usageCount (day, name, count) VALUES (?, ?, 1)
                ON CONFLICT(day, name) DO UPDATE SET count = count + 1
                """, arguments: [day(date), name])
        }
    }

    /// Uses per name since `since`, and the first day anything was counted at all (nil: never).
    static func totals(since: Date, in db: some DatabaseReader) -> (counts: [String: Int], firstDay: String?) {
        (try? db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name, SUM(count) AS total FROM usageCount WHERE day >= ? GROUP BY name",
                                        arguments: [day(since)])
            let first = try String.fetchOne(db, sql: "SELECT MIN(day) FROM usageCount")
            return (Dictionary(uniqueKeysWithValues: rows.map { ($0["name"] as String, $0["total"] as Int) }), first)
        }) ?? ([:], nil)
    }

    static func forget(in db: some DatabaseWriter) {
        _ = try? db.write { try $0.execute(sql: "DELETE FROM usageCount") }
    }

    /// Of `candidates` (what's in the layout or on the bar now), the ones not used once in the last `quietDays` —
    /// only once counting has been on that long, so a fresh install asks nothing.
    static func unused(_ candidates: [String], counts: [String: Int], firstDay: String?, now: Date = .now) -> [String] {
        guard let firstDay, firstDay <= day(now.addingTimeInterval(-Double(quietDays) * 86400)) else { return [] }
        return candidates.filter { (counts[$0] ?? 0) == 0 }
    }
}
