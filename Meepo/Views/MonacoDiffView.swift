import SwiftUI
import WebKit

/// VS Code's own editor (Monaco, bundled in Resources/Monaco) showing a diff: syntax colors, side by side or
/// inline, changed words, folded unchanged regions, minimap — the compare view one-to-one.
struct MonacoDiffView: NSViewRepresentable {
    /// nil = nothing to compare yet; `message` shows instead of the editor (binary file, reading…).
    struct Content: Equatable {
        var original = ""
        var modified = ""
        var path = ""
        var message: String?
        /// Just `modified` in a plain editor (the Explorer's file view), no diff.
        var isSingle = false
    }

    let content: Content
    let sideBySide: Bool
    /// Bumped by ↑/↓; the sign says which way.
    let navigation: Navigation
    var onChanges: (Int) -> Void = { _ in }

    struct Navigation: Equatable {
        var step = 0
        var direction = "next"
    }

    static var pageURL: URL? { Bundle.main.url(forResource: "diff", withExtension: "html", subdirectory: "Monaco") }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "meepo")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground") // no white flash before Monaco paints
        context.coordinator.web = web
        if let page = Self.pageURL {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChanges = onChanges
        if coordinator.shown != content || coordinator.sideBySide != sideBySide {
            let layoutOnly = coordinator.shown == content
            coordinator.shown = content
            coordinator.sideBySide = sideBySide
            coordinator.run(layoutOnly ? "meepoLayout(\(sideBySide))" : "meepoShow(\(Self.payload(content, sideBySide: sideBySide)))")
        }
        if coordinator.navigation != navigation {
            coordinator.navigation = navigation
            coordinator.run("meepoGo('\(navigation.direction)')")
        }
    }

    /// One JSON string literal, so any file text survives the trip into JavaScript.
    static func payload(_ content: Content, sideBySide: Bool) -> String {
        var object: [String: Any] = ["original": content.original, "modified": content.modified,
                                     "language": language(for: content.path), "sideBySide": sideBySide]
        if let message = content.message { object["message"] = message }
        if content.isSingle { object["single"] = true }
        let json = (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let literal = (try? JSONSerialization.data(withJSONObject: json, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) }
        return literal ?? "\"{}\""
    }

    /// Monaco language ids by file name, the ones VS Code picks for the same files.
    static func language(for path: String) -> String {
        let name = URL(filePath: path).lastPathComponent.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return "dockerfile" }
        if name == "makefile" { return "shell" }
        let byExtension = [
            "swift": "swift", "py": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
            "ts": "typescript", "tsx": "typescript", "json": "json", "md": "markdown", "html": "html", "htm": "html",
            "css": "css", "scss": "scss", "less": "less", "yml": "yaml", "yaml": "yaml", "go": "go", "rs": "rust",
            "rb": "ruby", "java": "java", "kt": "kotlin", "kts": "kotlin", "sh": "shell", "zsh": "shell", "bash": "shell",
            "sql": "sql", "xml": "xml", "plist": "xml", "php": "php", "c": "c", "h": "cpp", "cpp": "cpp", "hpp": "cpp",
            "m": "objective-c", "cs": "csharp", "dart": "dart", "toml": "ini", "ini": "ini", "env": "ini", "graphql": "graphql",
            "vue": "html", "lua": "lua", "r": "r", "scala": "scala", "tf": "hcl", "proto": "protobuf",
        ]
        return byExtension[URL(filePath: name).pathExtension] ?? "plaintext"
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var web: WKWebView?
        var shown: Content?
        var sideBySide = true
        var navigation = Navigation()
        var onChanges: (Int) -> Void = { _ in }
        private var isReady = false
        private var queued: [String] = []

        func run(_ script: String) {
            guard isReady else { queued.append(script); return }
            web?.evaluateJavaScript(script)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["ready"] != nil {
                isReady = true
                // Only the latest content matters once Monaco is up.
                if let last = queued.last(where: { $0.hasPrefix("meepoShow") }) { web?.evaluateJavaScript(last) }
                queued.removeAll()
            }
            if let changes = body["changes"] as? Int { onChanges(changes) }
        }
    }
}
