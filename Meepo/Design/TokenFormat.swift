import Foundation

/// Shared token number format: 812, 34.5K, 1.2M, 9.23B.
enum TokenFormat {
    static func short(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<1_000_000: String(format: value < 10_000 ? "%.1fK" : "%.0fK", Double(value) / 1_000)
        // B from where "%.1fM" would say 1000.0M, like Claude Code's /stats.
        case ..<999_950_000: String(format: value < 10_000_000 ? "%.2fM" : "%.1fM", Double(value) / 1_000_000)
        default: String(format: value < 10_000_000_000 ? "%.2fB" : "%.1fB", Double(value) / 1_000_000_000)
        }
    }
}
