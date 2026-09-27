import AppKit
import XCTest
@testable import Meepo

final class MarkdownTextTests: XCTestCase {
    private let note = """
        ## Leasing
        **Import from Excel**: upload the payment schedule.
        - works with *.xlsx*
        - see `docs/import.md`
        """

    func testMarkupIsGoneAndEveryLineStays() {
        let plain = MarkdownText.plain(note)
        XCTAssertFalse(plain.contains("**") || plain.contains("##") || plain.contains("`"))
        XCTAssertEqual(plain.components(separatedBy: "\n"), [
            "Leasing", "Import from Excel: upload the payment schedule.", "- works with .xlsx", "- see docs/import.md",
        ])
    }

    func testHeadingAndBoldAreBold() {
        let text = MarkdownText.attributed(note)
        let bold = text.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(text[$0.range].characters) }
        XCTAssertEqual(bold, ["Leasing", "Import from Excel"])
    }

    /// Model-written text: a link opens only a web page, never a file or another app.
    func testOnlyWebLinksStay() {
        let text = MarkdownText.attributed("[docs](https://example.com) [x](file:///etc/passwd) [y](x-apple.systempreferences:a) [z](HTTP://a.b)")
        XCTAssertEqual(text.runs.compactMap(\.link?.absoluteString), ["https://example.com", "HTTP://a.b"])
        XCTAssertNil(MarkdownText.rich("[x](file:///etc/passwd)").attribute(.link, at: 0, effectiveRange: nil))
    }

    /// RTF and HTML keep only real fonts; a presentation intent alone reaches Telegram or LinkedIn as plain text.
    func testRichTextHasABoldFont() {
        let rich = MarkdownText.rich("**Kaspi** payments")
        let font = rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let rest = rich.attribute(.font, at: rich.length - 1, effectiveRange: nil) as? NSFont
        XCTAssertFalse(rest?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testCopyPutsRichTextHTMLAndPlainText() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("meepo-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        MarkdownText.copy("**Kaspi** payments\n- in the app", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "Kaspi payments\n- in the app")
        XCTAssertNotNil(pasteboard.data(forType: .rtf))
        let html = String(decoding: try XCTUnwrap(pasteboard.data(forType: .html)), as: UTF8.self)
        XCTAssertTrue(html.contains("<b>"), html)
    }
}
