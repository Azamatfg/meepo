import Foundation

/// Code editors on this Mac, for a project's "Open in …" menu (Meepo has no editor of its own, SPEC §9).
enum Editors {
    struct IDE: Hashable {
        let name: String
        /// For `open -a`.
        let app: String
    }

    static let known = [IDE(name: "VS Code", app: "Visual Studio Code"), IDE(name: "Cursor", app: "Cursor"),
                        IDE(name: "Windsurf", app: "Windsurf"), IDE(name: "Zed", app: "Zed")]

    static var installed: [IDE] {
        known.filter { ide in
            ["/Applications", "\(NSHomeDirectory())/Applications"].contains { FileManager.default.fileExists(atPath: "\($0)/\(ide.app).app") }
        }
    }
}
