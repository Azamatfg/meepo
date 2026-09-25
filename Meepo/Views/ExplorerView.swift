import AppKit
import SwiftUI

/// VS Code's Explorer as a panel: the session folder as a tree, folders open on click, changed files
/// in their Source Control color; a file opens read-only in Monaco.
struct ExplorerSection: View {
    let root: String
    let changes: [GitPanel.FileChange]
    @State private var expanded: Set<String> = []
    /// Listings by folder ("" = root), read for the root and every open folder.
    @State private var children: [String: [FileTree.Entry]] = [:]
    @State private var opened: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(rows, id: \.entry.id) { row in entryRow(row.entry, depth: row.depth) }
            if children[""]?.isEmpty == true {
                Text("Empty folder").font(.caption).foregroundStyle(Tokens.textDim)
            }
        }
        // New files from claude show up without a click; only the root and open folders are read.
        .task(id: root) {
            expanded = []
            children = [:]
            while !Task.isCancelled {
                let dirs = [""] + expanded, root = root
                children = await Task.detached { Dictionary(uniqueKeysWithValues: dirs.map { ($0, FileTree.list($0, in: root)) }) }.value
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .sheet(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
            if let opened { FileViewer(root: root, path: opened) }
        }
    }

    /// The tree flattened in display order: an open folder's entries follow it, one level deeper.
    private var rows: [(entry: FileTree.Entry, depth: Int)] {
        var rows: [(entry: FileTree.Entry, depth: Int)] = []
        func walk(_ dir: String, _ depth: Int) {
            for entry in children[dir] ?? [] {
                rows.append((entry, depth))
                if entry.isDirectory, expanded.contains(entry.path) { walk(entry.path, depth + 1) }
            }
        }
        walk("", 0)
        return rows
    }

    private func entryRow(_ entry: FileTree.Entry, depth: Int) -> some View {
        let status = FileTree.status(of: entry, changes: changes)
        return Button { entry.isDirectory ? toggle(entry.path) : (opened = entry.path) } label: {
            HStack(spacing: 5) {
                if entry.isDirectory {
                    Image(systemName: expanded.contains(entry.path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Tokens.textDim).frame(width: 14)
                } else {
                    Image(systemName: FileIcon.symbol(for: entry.path)).font(.system(size: 11))
                        .foregroundStyle(FileIcon.color(for: entry.path)).frame(width: 14)
                }
                Text(entry.name).font(.system(size: 12))
                    .foregroundStyle(status.map(FileIcon.statusColor) ?? Tokens.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let status {
                    Text(DiffViewer.letter(status)).font(.system(size: 11, weight: .semibold)).foregroundStyle(FileIcon.statusColor(status))
                }
            }
            .padding(.leading, CGFloat(depth) * 12)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.path)
    }

    private func toggle(_ dir: String) {
        if expanded.remove(dir) != nil { return }
        expanded.insert(dir)
        let root = root
        Task { children[dir] = await Task.detached { FileTree.list(dir, in: root) }.value }
    }
}

/// One file from the Explorer in VS Code's editor, read-only: syntax colors, minimap.
private struct FileViewer: View {
    @Environment(\.dismiss) private var dismiss
    let root: String
    let path: String
    @State private var content = MonacoDiffView.Content(message: "Loading…")

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(URL(filePath: path).lastPathComponent).font(.system(size: 13)).foregroundStyle(Tokens.vsText)
                Text((path as NSString).deletingLastPathComponent).font(.system(size: 12)).foregroundStyle(Tokens.vsTextDim)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: "\(root)/\(path)")]) } label: {
                    Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Tokens.vsText).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(Tokens.vsText).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close (Esc)")
            }
            .padding(.horizontal, 12)
            .frame(height: 35)
            .background(Tokens.vsTitle)
            MonacoDiffView(content: content, sideBySide: false, navigation: MonacoDiffView.Navigation())
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 780)
        .background(Tokens.vsEditor)
        .preferredColorScheme(.dark)
        .task { content = await Task.detached { [root, path] in Self.load("\(root)/\(path)", as: path) }.value }
    }

    /// Too big or binary files get a message instead of an editor.
    nonisolated static func load(_ file: String, as path: String) -> MonacoDiffView.Content {
        guard let data = FileManager.default.contents(atPath: file) else {
            return MonacoDiffView.Content(path: path, message: "Can't read this file.")
        }
        if data.count > 5_000_000 { return MonacoDiffView.Content(path: path, message: "Over 5 MB — not shown.") }
        if DiffViewer.isBinary(data) { return MonacoDiffView.Content(path: path, message: "Binary file — not shown.") }
        return MonacoDiffView.Content(modified: String(decoding: data, as: UTF8.self), path: path, isSingle: true)
    }
}
