import AppKit

/// Menu bar icon: the app icon's "m." in one colour, a template image so macOS tints it for the theme.
enum MenuBarIcon {
    static let mark: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let font = NSFont(name: "TT Commons Bold", size: 17) ?? .systemFont(ofSize: 16, weight: .heavy)
            let m = NSAttributedString(string: "m", attributes: [.font: font, .foregroundColor: NSColor.black])
            let size = m.size()
            m.draw(at: NSPoint(x: 0, y: (18 - size.height) / 2))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: size.width + 1, y: 3.5, width: 4, height: 4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
