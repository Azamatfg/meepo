import AppKit
import SwiftUI

/// All app colors — the "Paper" look (Meepo 2.0, decided 2026-09-25): warm paper, ink, ultramarine for work,
/// vermilion for "needs you". Change the palette here only. Each color has a light and a dark value; which one
/// shows follows the app's appearance (Settings → Appearance: System, Light or Dark).
enum Tokens {
    // Paper roles.
    static let ground        = Color(light: 0xF1EEE6, dark: 0x1A1916) // window
    static let surface       = Color(light: 0xFBFAF6, dark: 0x22211D) // panels, cards
    static let raised        = Color(light: 0xFFFFFF, dark: 0x2D2C27) // selected tab/row, dialogs
    static let line          = Color(light: 0xE0DBCE, dark: 0x3A3832) // borders, dividers
    static let ghost         = text.opacity(0.06)                     // quiet buttons
    static let work          = Color(light: 0x2140D9, dark: 0x7D95FF) // working, selected, primary
    static let workTint      = work.opacity(0.10)
    static let need          = Color(light: 0xC2440F, dark: 0xF07A42) // waiting for you — the only loud color
    static let needTint      = need.opacity(0.12)
    static let idle          = Color(light: 0xB0A998, dark: 0x6F6A5E)
    static let statusBar     = Color(light: 0xE9E5DA, dark: 0x201F1B)
    static let added         = Color(light: 0x2E7D32, dark: 0x6CC070) // new files in Source Control

    // v1 names, kept so every view moved to Paper at once; new code uses the roles above.
    static let grass         = surface                // panel background
    static let grassLight    = Color(light: 0xEFEBE1, dark: 0x2A2924) // hovers
    static let grassDeep     = ground                 // empty states, section wells
    static let dirt          = statusBar              // list underlays, dividers
    static let hood          = Color(light: 0x8A6A4A, dark: 0xB08E6B)
    static let selection     = work                   // selected / active only
    static let selectionSoft = Color(light: 0x6F84E0, dark: 0x5A6FC4) // unselected, inactive bars, CI passed
    static let alert         = need                   // "waiting for you" only
    static let screen        = Color(light: 0x1F5F8B, dark: 0x72B4E0) // code, commit authors, explanations
    static let screenDeep    = Color(light: 0x4A6A80, dark: 0x8CA7BA)
    static let frameLight    = raised
    static let frameMid      = statusBar              // bars and plates
    static let frameDark     = Color(light: 0xD6D0C2, dark: 0x46433C)
    static let terminalBg    = Color(nsColor: Terminal.background)
    static let danger        = Color(light: 0xB3261E, dark: 0xF2665C)
    static let warn          = Color(light: 0x9A6200, dark: 0xE0A43A) // time to sync; amber stays readable on both
    static let text          = Color(nsColor: Terminal.foreground)
    static let textDim       = Color(light: 0x5F5A50, dark: 0xA39D90)

    /// The terminal's own colors, as AppKit colors: SwiftTerm takes NSColor and is told again when the appearance changes.
    enum Terminal {
        static let background = NSColor(light: 0xF6F3EC, dark: 0x1E1D1A)
        static let foreground = NSColor(light: 0x1B1A17, dark: 0xECE8DF)
        static let caret      = NSColor(light: 0x2140D9, dark: 0x7D95FF)
    }

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

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(light: light, dark: dark))
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

    /// Resolves against the appearance it's drawn in: the dark value under Dark Aqua, else the light one.
    convenience init(light: UInt32, dark: UInt32) {
        let (lightColor, darkColor) = (NSColor(hex: light), NSColor(hex: dark))
        self.init(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor }
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
