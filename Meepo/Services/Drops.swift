import AppKit
import UniformTypeIdentifiers

/// Files dragged into meepo from Finder, a screenshot's thumbnail or another app.
enum Drops {
    /// File URLs on a drag's pasteboard.
    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Every item with every type it offers, so text, files and images all survive.
    static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [:]) { result, type in result[type] = item.data(forType: type) }
        }
    }

    static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        })
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// A path the way Terminal.app types a dropped file: shell characters escaped with a backslash.
    static func escapedPath(_ path: String) -> String {
        path.reduce(into: "") { result, character in
            if " \\'\"()[]{}&;|<>*?!$`#~".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    enum CopyError: LocalizedError {
        case intoItself
        /// Some were copied before one failed: "Copied 2 of 5 into docs — couldn't copy a.pdf: …".
        case partly(copied: Int, of: Int, into: String, failed: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .intoItself: "Can't copy a folder into itself"
            case let .partly(copied, total, folder, failed, reason): "Copied \(copied) of \(total) into \(folder) — couldn't copy \(failed): \(reason)"
            }
        }
    }

    /// The path as the file system knows it: symlinks resolved, and the case on disk ("Docs" for "docs").
    static func canonicalPath(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? url.resolvingSymlinksInPath().path
    }

    /// Copies files into `folder` like Finder: a name that's taken becomes "name 2.ext", "name 3.ext"…
    /// A folder never goes into itself or its own subfolder (the copy would nest again and again), and then
    /// nothing is copied. `copied` hears of each copy as soon as it's made, so one that fails later can't hide
    /// it. Blocking; call off the main thread. Returns the copies.
    static func copy(_ urls: [URL], into folder: URL, copied: (URL) -> Void = { _ in }) throws -> [URL] {
        let fm = FileManager.default
        let destination = canonicalPath(folder) + "/"
        if urls.contains(where: { destination.hasPrefix(canonicalPath($0) + "/") }) { throw CopyError.intoItself }
        var copies: [URL] = []
        for url in urls {
            let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            var target = folder.appending(path: url.lastPathComponent)
            var number = 2
            while fm.fileExists(atPath: target.path) {
                target = folder.appending(path: stem + " \(number)" + (ext.isEmpty ? "" : "." + ext))
                number += 1
            }
            do {
                try fm.copyItem(at: url, to: target)
            } catch where !copies.isEmpty {
                throw CopyError.partly(copied: copies.count, of: urls.count, into: folder.lastPathComponent,
                                       failed: url.lastPathComponent, reason: error.localizedDescription)
            }
            copies.append(target)
            copied(target)
        }
        return copies
    }

    /// Where ⌘V in Explorer puts Finder's files (relative to `root`, "" = the root): into the selected folder,
    /// next to the selected file, into the root when nothing is selected. A folder pasted onto itself lands
    /// next to it as "name 2", like Finder.
    static func pasteTarget(selected: FileTree.Entry?, pasting urls: [URL], root: String) -> String {
        guard let selected else { return "" }
        let parent = (selected.path as NSString).deletingLastPathComponent
        guard selected.isDirectory else { return parent }
        let folder = canonicalPath(URL(filePath: root).appending(path: selected.path))
        return urls.contains { canonicalPath($0) == folder } ? parent : selected.path
    }
}

extension AppStore {
    /// Files dropped on a session's terminal: images go to Claude as images (Ctrl+V, like a pasted screenshot),
    /// other files as their paths, the way Terminal.app types them.
    func dropFiles(_ urls: [URL], into sessionId: Int64) {
        let isShell = sessions.first { $0.id == sessionId }?.sshHost != nil // a server shell takes paths only
        let images = isShell ? [] : urls.filter(Drops.isImage).compactMap { url in NSImage(contentsOf: url).map { (url, $0) } }
        let paths = urls.filter { url in !images.contains { $0.0 == url } }
        if !paths.isEmpty { type(paths.map { Drops.escapedPath($0.path) }.joined(separator: " ") + " ", into: sessionId) }
        pasteImages(images.map(\.1), into: sessionId)
    }

    /// Claude Code pastes images with Ctrl+V: each one goes on the clipboard and Ctrl+V is pressed in that
    /// terminal, one after another. The user's clipboard comes back afterwards, unless they copied something new.
    func pasteImages(_ images: [NSImage], into sessionId: Int64) {
        guard !images.isEmpty else { return }
        let previous = pasting
        pasting = Task { @MainActor in
            await previous?.value
            let pasteboard = NSPasteboard.general
            let saved = Drops.snapshot(pasteboard)
            for image in images {
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
                let ours = pasteboard.changeCount
                type("\u{16}", into: sessionId)
                // claude reads the image asynchronously after the keypress; the next one or the old clipboard waits.
                try? await Task.sleep(for: .seconds(image === images.last ? 2 : 1))
                guard pasteboard.changeCount == ours else { return }
            }
            Drops.restore(saved, to: pasteboard)
        }
    }
}
