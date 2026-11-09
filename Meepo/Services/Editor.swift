import AppKit
import Observation
import WebKit

/// VS Code's editor above the terminals: the files open in it as tabs, edited in Monaco (Resources/Monaco/editor.html).
/// One web view for the whole window, kept here so unsaved edits survive the center switching to Home and back.
@MainActor @Observable
final class Editor {
    struct File: Identifiable, Equatable {
        /// Absolute.
        let path: String
        /// The text on disk when it was last read or saved: a save checks the disk still holds it.
        var saved: String
        var isDirty = false
        var id: String { path }
        var name: String { URL(filePath: path).lastPathComponent }
    }

    private(set) var files: [File] = []
    private(set) var active: String?
    /// Why a file didn't open or save ("Binary file — not opened").
    var notice: String?

    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private var bridge: Bridge?
    @ObservationIgnored private var watching: Task<Void, Never>?

    var activeFile: File? { files.first { $0.path == active } }

    /// The web view Monaco runs in, made on first use.
    var webView: WKWebView {
        if let web = bridge?.web { return web }
        let bridge = Bridge(editor: self)
        self.bridge = bridge
        return bridge.web
    }

    func open(_ path: String) {
        if files.contains(where: { $0.path == path }) { return activate(path) }
        let text: String
        switch Self.read(path) {
        case let .success(read): text = read
        case let .failure(why): notice = "\(URL(filePath: path).lastPathComponent): \(why.message)"; return
        }
        files.append(File(path: path, saved: text))
        notice = nil
        bridge(open: path, text: text)
        active = path
        watch()
    }

    func activate(_ path: String) {
        guard let file = files.first(where: { $0.path == path }) else { return }
        active = path
        bridge(open: path, text: file.saved)
    }

    /// The tab's ✕: an unsaved file asks first.
    func requestClose(_ path: String) {
        guard let file = files.first(where: { $0.path == path }) else { return }
        guard file.isDirty else { return close(path) }
        store?.confirmation = PixelConfirmation(
            title: "Close \(file.name) without saving?", message: "Your changes to it are lost.", action: "Don't Save",
            alternative: ("Save", { [weak self] in
                self?.closeAfterSave = path
                self?.bridge?.run("meepoRequestSave(\(Self.literal(path)))")
            })
        ) { [weak self] in self?.close(path) }
    }

    @ObservationIgnored private var closeAfterSave: String?

    func close(_ path: String) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        files.remove(at: index)
        bridge?.run("meepoClose(\(Self.literal(path)))")
        if active == path {
            active = files.isEmpty ? nil : files[min(index, files.count - 1)].path
            if let active { activate(active) }
        }
        if files.isEmpty { watching?.cancel(); watching = nil }
    }

    var unsavedCount: Int { files.filter(\.isDirty).count }

    // MARK: From Monaco

    fileprivate func setDirty(_ path: String, _ isDirty: Bool) {
        guard let index = files.firstIndex(where: { $0.path == path }), files[index].isDirty != isDirty else { return }
        files[index].isDirty = isDirty
    }

    /// ⌘S. The disk changed since it was read (Claude edited it): ask before writing over that.
    fileprivate func save(_ path: String, text: String, overwrite: Bool = false) {
        guard let file = files.first(where: { $0.path == path }), let backups = store?.backupsDir else { return }
        do {
            switch try Self.write(text, to: path, expecting: overwrite ? nil : file.saved, backups: backups) {
            case .saved:
                markSaved(path, text: text)
                if closeAfterSave == path { closeAfterSave = nil; close(path) }
            case let .changedOnDisk(disk):
                store?.confirmation = PixelConfirmation(
                    title: "\(file.name) changed on disk", message: "Claude or another app changed it after you opened it.",
                    action: "Overwrite",
                    alternative: ("Load the disk version", { [weak self] in self?.reload(path, text: disk) })
                ) { [weak self] in self?.save(path, text: text, overwrite: true) }
            }
        } catch {
            notice = "Couldn't save \(file.name): \(error.localizedDescription)"
        }
    }

    private func markSaved(_ path: String, text: String) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        files[index].saved = text
        files[index].isDirty = false
        bridge?.run("meepoSaved(\(Self.literal(path)))")
    }

    private func reload(_ path: String, text: String) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        files[index].saved = text
        files[index].isDirty = false
        bridge?.run("meepoReload(\(Self.payload(path: path, text: text)))")
    }

    /// Claude's edits show up in a file you haven't touched, like VS Code; a touched one asks on save.
    private func watch() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let clean = files.filter { !$0.isDirty }
                let disk = await Task.detached { clean.map { (path: $0.path, text: try? Self.read($0.path).get()) } }.value
                for (path, text) in disk {
                    guard let text, let file = files.first(where: { $0.path == path }), !file.isDirty, file.saved != text else { continue }
                    reload(path, text: text)
                }
            }
        }
    }

    private func bridge(open path: String, text: String) {
        _ = webView
        bridge?.run("meepoOpen(\(Self.payload(path: path, text: text)))")
    }

    // MARK: Disk (nonisolated, tested)

    struct ReadError: Error { let message: String }

    nonisolated static func read(_ path: String) -> Result<String, ReadError> {
        guard let data = FileManager.default.contents(atPath: path) else { return .failure(ReadError(message: "can't read it")) }
        if data.count > 5_000_000 { return .failure(ReadError(message: "over 5 MB — not opened")) }
        if DiffViewer.isBinary(data) { return .failure(ReadError(message: "binary file — not opened")) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(ReadError(message: "not UTF-8 — not opened")) }
        return .success(text)
    }

    enum WriteResult: Equatable { case saved, changedOnDisk(String) }

    /// Writes `text` unless the disk no longer holds `expecting` (nil = write anyway). The old file is backed up and the
    /// edit logged in Tools → Changes (SPEC §8), where it can be undone.
    nonisolated static func write(_ text: String, to path: String, expecting: String?, backups: URL) throws -> WriteResult {
        let url = URL(filePath: path)
        let disk = try? read(path).get()
        if let expecting, let disk, disk != expecting { return .changedOnDisk(disk) }
        if disk == text { return .saved }
        let backup = try ChangeLog.backup(url, folder: "edits", backups: backups)
        try Data(text.utf8).write(to: url, options: .atomic)
        ChangeLog.record("Edit \(url.lastPathComponent)", file: url, backup: backup, backups: backups)
        return .saved
    }

    // MARK: Into JavaScript

    nonisolated static func literal(_ string: String) -> String {
        (try? JSONSerialization.data(withJSONObject: string, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    nonisolated static func payload(path: String, text: String) -> String {
        let object = ["path": path, "text": text, "language": MonacoDiffView.language(for: path)]
        let json = (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return literal(json)
    }

    /// The web view and its messages: ready, dirty, save.
    @MainActor
    private final class Bridge: NSObject, WKScriptMessageHandler {
        let web: WKWebView
        weak var editor: Editor?
        private var isReady = false
        private var queued: [String] = []

        init(editor: Editor) {
            let configuration = WKWebViewConfiguration()
            web = WKWebView(frame: .zero, configuration: configuration)
            self.editor = editor
            super.init()
            configuration.userContentController.add(self, name: "meepo")
            web.setValue(false, forKey: "drawsBackground")
            if let page = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "Monaco") {
                web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
            }
        }

        func run(_ script: String) {
            guard isReady else { queued.append(script); return }
            web.evaluateJavaScript(script)
        }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let body = message.body as? [String: Any] else { return }
                if body["ready"] != nil {
                    isReady = true
                    queued.forEach { web.evaluateJavaScript($0) }
                    queued.removeAll()
                }
                if let path = body["dirty"] as? String, let isDirty = body["value"] as? Bool { editor?.setDirty(path, isDirty) }
                if let path = body["save"] as? String, let text = body["text"] as? String { editor?.save(path, text: text) }
            }
        }
    }
}
