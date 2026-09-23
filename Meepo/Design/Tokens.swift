import AppKit
import SwiftUI

/// All app colors, from design/MEEPO_DESIGN.md §3 (sampled from assets/ref). Change the palette here only.
/// The look is a fixed dark "RTS map", so there are no light variants.
enum Tokens {
    static let grass         = Color(hex: 0x2C4B1E) // panel background
    static let grassLight    = Color(hex: 0x427F41) // hovers, light areas
    static let grassDeep     = Color(hex: 0x233624) // empty states, dark areas
    static let dirt          = Color(hex: 0x3F2F1D) // paths, dividers, list underlays
    static let hood          = Color(hex: 0x7B4B2C) // secondary warm accent
    static let selection     = Color(hex: 0x11F10F) // selected / active only
    static let selectionSoft = Color(hex: 0x44922D) // unselected rings, inactive bars
    static let alert         = Color(hex: 0xF16704) // "waiting for you" only
    static let screen        = Color(hex: 0x1EC8EC) // terminal and code
    static let screenDeep    = Color(hex: 0x336C81)
    static let frameLight    = Color(hex: 0xB3B3B2)
    static let frameMid      = Color(hex: 0x636363)
    static let frameDark     = Color(hex: 0x404040)
    static let terminalBg    = Color(hex: 0x0E1710)
    static let danger        = Color(hex: 0xE0402A)
    static let warn          = Color(hex: 0xF2C230) // time to sync
    static let text          = Color(hex: 0xE8F0E0)
    static let textDim       = Color(hex: 0xE8F0E0).opacity(0.65)
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Bundled OFL fonts (Meepo/Resources/Fonts): Silkscreen for titles/badges/buttons (16 pt and up only),
/// JetBrains Mono for terminal, branches and numbers; the system font for small print.
enum Fonts {
    static func register() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func title(_ size: CGFloat = 16) -> Font { .custom("Silkscreen", size: max(size, 16)) }
    static func mono(_ size: CGFloat = 13) -> Font { .custom("JetBrains Mono", size: size) }

    static func terminal(_ size: CGFloat = 13) -> NSFont {
        NSFontManager.shared.font(withFamily: "JetBrains Mono", traits: [], weight: 5, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
