import AppKit
import SwiftUI

/// All app colors live here so the palette can be swapped in one place.
/// Placeholder palette from SPEC.md §5 (dark values); light values are derived.
enum Tokens {
    static let background = Color(light: 0xECE7DC, dark: 0x1B1F24) // stone
    static let surface    = Color(light: 0xDCD5C6, dark: 0x262B32)
    static let text       = Color(light: 0x1B1F24, dark: 0xECE7DC)
    static let gold       = Color(light: 0xA8832F, dark: 0xC9A24A)
    static let moss       = Color(light: 0x3E6A2C, dark: 0x4E7A3A)
    static let glow       = Color(light: 0x2A8F88, dark: 0x3FB8AF)
    static let fire       = Color(light: 0xC45F1E, dark: 0xE0762F)
    static let danger     = Color(light: 0x9E2B25, dark: 0xD0554B)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
