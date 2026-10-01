import SwiftUI
import WebKit

/// A Mermaid diagram (bundled mermaid.js, offline) you can drag and zoom — database schemas, DRAW.
struct MermaidView: NSViewRepresentable {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    static var pageURL: URL? { Bundle.main.url(forResource: "diagram", withExtension: "html", subdirectory: "Mermaid") }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let page = Self.pageURL { web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let dark = colorScheme == .dark
        let coordinator = context.coordinator
        guard coordinator.text != text || coordinator.dark != dark else { return } // the same picture: nothing to encode
        (coordinator.text, coordinator.dark) = (text, dark)
        coordinator.show("meepoRender(\(Self.literal(text)), \(dark))")
    }

    /// The text as one JavaScript string literal, whatever it holds.
    static func literal(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        var text: String?
        var dark: Bool?
        /// The last picture asked for; drawn now, or as soon as the page has loaded.
        private var script: String?
        private var isLoaded = false

        func show(_ script: String) {
            self.script = script
            if isLoaded { web?.evaluateJavaScript(script) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let script { webView.evaluateJavaScript(script) }
        }
    }
}
