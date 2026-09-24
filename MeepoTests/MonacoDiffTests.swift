import WebKit
import XCTest
@testable import Meepo

/// The bundled Monaco actually loads from file:// in a WKWebView and computes a diff (the compare view's engine).
@MainActor
private final class MessageSink: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    var onMessage: ([String: Any]) -> Void = { _ in }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        messages.append(body)
        onMessage(body)
    }
}

@MainActor
final class MonacoDiffTests: XCTestCase {

    func testMonacoLoadsAndFindsTheChanges() async throws {
        let page = try XCTUnwrap(MonacoDiffView.pageURL, "Monaco isn't in the app bundle")
        let sink = MessageSink()
        let ready = expectation(description: "Monaco ready")
        let diffed = expectation(description: "diff computed")
        sink.onMessage = { body in
            if body["ready"] != nil { ready.fulfill() }
            if body["changes"] != nil { diffed.fulfill() }
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(sink, name: "meepo")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 520), configuration: configuration)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        // Monaco paints on animation frames, which a window never put on screen doesn't get.
        let snapshot = ProcessInfo.processInfo.environment["MEEPO_SNAPSHOT_DIR"] != nil
        window.setFrameOrigin(snapshot ? NSPoint(x: 40, y: 40) : NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        await fulfillment(of: [ready], timeout: 20)

        let content = MonacoDiffView.Content(
            original: "import os\n\ndef load(key):\n    rows = query.all()\n    return rows\n",
            modified: "import os\n\ndef load(key):\n    rows = cache.get(key) or query.all()\n    log(rows)\n    return rows\n",
            path: "app/views.py")
        _ = try await web.evaluateJavaScript("meepoShow(\(MonacoDiffView.payload(content, sideBySide: true)))")
        await fulfillment(of: [diffed], timeout: 20)
        XCTAssertEqual(sink.messages.compactMap { $0["changes"] as? Int }.last, 1)   // one change block: line 4 → lines 4–5

        if let out = ProcessInfo.processInfo.environment["MEEPO_SNAPSHOT_DIR"] {
            try await Task.sleep(for: .milliseconds(1500))
            let image = try await web.takeSnapshot(configuration: nil)
            let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: URL(filePath: out).appending(path: "monaco-diff.png"))
        }
    }

    func testLanguageIdsLikeVSCode() {
        XCTAssertEqual(MonacoDiffView.language(for: "Meepo/App/AppStore.swift"), "swift")
        XCTAssertEqual(MonacoDiffView.language(for: "backend/views.py"), "python")
        XCTAssertEqual(MonacoDiffView.language(for: ".gitlab-ci.yml"), "yaml")
        XCTAssertEqual(MonacoDiffView.language(for: "deploy/Dockerfile"), "dockerfile")
        XCTAssertEqual(MonacoDiffView.language(for: "LICENSE"), "plaintext")
    }
}
