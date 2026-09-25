import Foundation

/// Where the window's panels sit (Meepo 2.0, layout "c"): three zones around the terminals, and how many
/// sessions' terminals share the center. Presets are fixed layouts; moving anything makes it Custom.
struct ShellLayout: Codable, Equatable {
    enum Panel: String, Codable, CaseIterable, Identifiable {
        case sessions, explorer, changes, ci, events, waiting
        var id: String { rawValue }
    }

    enum Zone: String, Codable, CaseIterable { case left, right, bottom }

    enum Preset: String, Codable, CaseIterable, Identifiable {
        case focus, deck, full, custom
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var left: [Panel]
    var right: [Panel]
    var bottom: [Panel]
    /// Terminals side by side: 1, 2 or 4 (a 2×2 grid).
    var split: Int

    static let splits = [1, 2, 4]

    /// nil for `.custom` — that one is whatever the user saved.
    static func preset(_ preset: Preset) -> ShellLayout? {
        switch preset {
        case .focus: ShellLayout(left: [], right: [.changes, .waiting], bottom: [], split: 1)
        // Side zones on both sides leave ~780 pt at 1440 wide — one terminal. Presets with several keep one side.
        case .deck: ShellLayout(left: [.sessions], right: [], bottom: [], split: 4)
        case .full: ShellLayout(left: [.explorer, .changes], right: [], bottom: [.events, .ci], split: 2)
        case .custom: nil
        }
    }

    subscript(zone: Zone) -> [Panel] {
        get {
            switch zone {
            case .left: left
            case .right: right
            case .bottom: bottom
            }
        }
        set {
            switch zone {
            case .left: left = newValue
            case .right: right = newValue
            case .bottom: bottom = newValue
            }
        }
    }

    func zone(of panel: Panel) -> Zone? {
        Zone.allCases.first { self[$0].contains(panel) }
    }

    /// A panel lives in one zone at a time; moving it to its own zone sends it to that zone's end.
    mutating func move(_ panel: Panel, to zone: Zone) {
        remove(panel)
        self[zone].append(panel)
    }

    mutating func remove(_ panel: Panel) {
        for zone in Zone.allCases { self[zone].removeAll { $0 == panel } }
    }

    /// The rail's icons: hide a shown panel, or open a hidden one on the left.
    mutating func toggle(_ panel: Panel) {
        if zone(of: panel) != nil { remove(panel) } else { self[.left].insert(panel, at: 0) }
    }
}
