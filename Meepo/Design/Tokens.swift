import AppKit
import SwiftUI

/// All app colors — the "Paper" look (Meepo 2.0, decided 2026-09-25): warm paper, ink, ultramarine for work,
/// vermilion for "needs you". Change the palette here only. Light only for now.
enum Tokens {
    // Paper roles.
    static let ground        = Color(hex: 0xF1EEE6) // window
    static let surface       = Color(hex: 0xFBFAF6) // panels, cards
    static let raised        = Color(hex: 0xFFFFFF) // selected tab/row, dialogs
    static let line          = Color(hex: 0xE0DBCE) // borders, dividers
    static let ghost         = Color(hex: 0x1B1A17).opacity(0.06) // quiet buttons
    static let work          = Color(hex: 0x2140D9) // working, selected, primary
    static let workTint      = Color(hex: 0x2140D9).opacity(0.08)
    static let need          = Color(hex: 0xC2440F) // waiting for you — the only loud color
    static let needTint      = Color(hex: 0xC2440F).opacity(0.10)
    static let idle          = Color(hex: 0xB0A998)
    static let statusBar     = Color(hex: 0xE9E5DA)
    static let added         = Color(hex: 0x2E7D32) // new files in Source Control

    // v1 names, kept so every view moved to Paper at once; new code uses the roles above.
    static let grass         = surface                // panel background
    static let grassLight    = Color(hex: 0xEFEBE1)   // hovers
    static let grassDeep     = ground                 // empty states, section wells
    static let dirt          = statusBar              // list underlays, dividers
    static let hood          = Color(hex: 0x8A6A4A)
    static let selection     = work                   // selected / active only
    static let selectionSoft = Color(hex: 0x6F84E0)   // unselected, inactive bars, CI passed
    static let alert         = need                   // "waiting for you" only
    static let screen        = Color(hex: 0x1F5F8B)   // code, commit authors, explanations
    static let screenDeep    = Color(hex: 0x4A6A80)
    static let frameLight    = raised
    static let frameMid      = statusBar              // bars and plates
    static let frameDark     = Color(hex: 0xD6D0C2)
    static let terminalBg    = Color(hex: 0xF6F3EC)
    static let danger        = Color(hex: 0xB3261E)
    static let warn          = Color(hex: 0x9A6200)   // time to sync; dark amber stays readable on paper
    static let text          = Color(hex: 0x1B1A17)
    static let textDim       = Color(hex: 0x5F5A50)

    // The compare view copies VS Code's Dark+ look on purpose (user decision 2026-09-24).
    static let vsEditor      = Color(hex: 0x1E1E1E)
    static let vsSideBar     = Color(hex: 0x252526)
    static let vsTitle       = Color(hex: 0x2D2D2D)
    static let vsBorder      = Color(hex: 0x3C3C3C)
    static let vsText        = Color(hex: 0xCCCCCC)
    static let vsTextDim     = Color(hex: 0x8B8B8B)
    static let vsListActive  = Color(hex: 0x04395E)
    static let vsModified    = Color(hex: 0xE2C08D)
    static let vsAdded       = Color(hex: 0x73C991)
    static let vsDeleted     = Color(hex: 0xC74E39)
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

/// TT Commons for the interface when it's installed (it's commercial, so Meepo doesn't ship it), else the system font;
/// bundled JetBrains Mono (OFL) for the terminal, branches and numbers.
enum Fonts {
    static func register() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static let hasCommons = NSFontManager.shared.availableFontFamilies.contains("TT Commons")

    static func ui(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        hasCommons ? .custom("TT Commons", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    /// Headings and labels. v1 passed 16 — the pixel font's minimum — for small labels; those become 14.
    static func title(_ size: CGFloat = 16) -> Font { ui(size <= 16 ? 14 : size, weight: .bold) }
    static func mono(_ size: CGFloat = 13) -> Font { .custom("JetBrains Mono", size: size) }

    static func terminal(_ size: CGFloat = 13) -> NSFont {
        NSFontManager.shared.font(withFamily: "JetBrains Mono", traits: [], weight: 5, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
