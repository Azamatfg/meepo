import AppKit

/// Menu bar icon (design §7): a one-colour hood silhouette, template image so macOS tints it for the theme.
enum MenuBarIcon {
    static let hood: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let hood = NSBezierPath()
            hood.move(to: NSPoint(x: 9, y: 17.5)) // pointed tip
            hood.curve(to: NSPoint(x: 14.5, y: 7), controlPoint1: NSPoint(x: 13, y: 16), controlPoint2: NSPoint(x: 14.5, y: 11.5))
            hood.line(to: NSPoint(x: 17, y: 0.5))
            hood.line(to: NSPoint(x: 1, y: 0.5))
            hood.line(to: NSPoint(x: 3.5, y: 7))
            hood.curve(to: NSPoint(x: 9, y: 17.5), controlPoint1: NSPoint(x: 3.5, y: 11.5), controlPoint2: NSPoint(x: 5, y: 16))
            hood.close()
            hood.append(NSBezierPath(ovalIn: NSRect(x: 5.5, y: 3.5, width: 7, height: 8))) // face opening
            hood.windingRule = .evenOdd
            NSColor.black.setFill()
            hood.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
