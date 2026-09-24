import Foundation

/// Shared token number format: 812, 34.5K, 1.2M.
enum TokenFormat {
    static func short(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<1_000_000: String(format: value < 10_000 ? "%.1fK" : "%.0fK", Double(value) / 1_000)
        default: String(format: value < 10_000_000 ? "%.2fM" : "%.1fM", Double(value) / 1_000_000)
        }
    }
}
