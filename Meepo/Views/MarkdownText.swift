import AppKit
import SwiftUI

/// Claude's Markdown shown formatted instead of with its "**": bold, italic, `code` and links inline; a heading
/// becomes a bold line, list markers stay as typed. Every line stays a line (the full Markdown parser and
/// `Notifier.plainText` join them).
enum MarkdownText {
    /// For `Text`: inline Markdown line by line; "# Title" becomes a bold "Title".
    static func attributed(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            if index > 0 { result += AttributedString("\n") }
            guard let heading = line.firstMatch(of: /^ {0,3}#{1,6}\s+(.*)$/) else {
                result += inline(line)
                continue
            }
            var bold = inline(String(heading.1))
            for run in bold.runs {
                bold[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            }
            result += bold
        }
        return result
    }

    /// The text without its markup, lines kept; a web link keeps its address after its words ("here (https://…)").
    static func plain(_ markdown: String) -> String {
        let text = attributed(markdown)
        // Runs by link only: bold inside one link must not repeat its address.
        return text.runs[\.link].map { link, range in
            let words = String(text[range].characters)
            guard let link, words != link.absoluteString else { return words }
            return "\(words) (\(link.absoluteString))"
        }.joined()
    }

    /// Bold and italic as real fonts: RTF and HTML drop a presentation intent, so the pasteboard needs these.
    static func rich(_ markdown: String, size: CGFloat = 13) -> NSAttributedString {
        let text = attributed(markdown)
        let result = NSMutableAttributedString()
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            let base = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base]
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }

    /// COPY: RTF and HTML keep the bold in Telegram, Mail and Slack; plain text for everything else (a LinkedIn post).
    static func copy(_ markdown: String, to pasteboard: NSPasteboard = .general) {
        let rich = rich(markdown)
        let range = NSRange(location: 0, length: rich.length)
        pasteboard.clearContents()
        if let rtf = rich.rtf(from: range) { pasteboard.setData(rtf, forType: .rtf) }
        if let html = try? rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) {
            pasteboard.setData(html, forType: .html)
        }
        pasteboard.setString(plain(markdown), forType: .string)
    }

    /// Links stay only for http(s): the text is model-written, and a file:// or app-scheme link would open things.
    private static func inline(_ line: String) -> AttributedString {
        var text = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
        let unsafe = text.runs.filter { run in run.link.map { !["http", "https"].contains($0.scheme?.lowercased() ?? "") } ?? false }
        for run in unsafe { text[run.range].link = nil }
        return text
    }
}
