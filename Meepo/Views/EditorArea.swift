import AppKit
import SwiftUI
import WebKit

/// VS Code's editor group above the terminals: a tab per open file (● unsaved, ✕ closes), Monaco below it.
struct EditorArea: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let editor = store.editor
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(editor.files) { file in tab(file, isActive: file.path == editor.active) }
                }
            }
            .frame(height: 35)
            .background(Tokens.vsTitle)
            if let notice = editor.notice {
                HStack {
                    Text(notice).font(.system(size: 12)).foregroundStyle(Tokens.vsTextDim).lineLimit(1)
                    Spacer()
                    Button("✕") { editor.notice = nil }.buttonStyle(.plain).foregroundStyle(Tokens.vsTextDim)
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Tokens.vsSideBar)
            }
            MonacoHost(web: editor.webView)
        }
        .background(Tokens.vsEditor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func tab(_ file: Editor.File, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: FileIcon.symbol(for: file.path)).font(.system(size: 11)).foregroundStyle(FileIcon.color(for: file.path))
            Text(file.name).font(.system(size: 12)).foregroundStyle(isActive ? Tokens.vsText : Tokens.vsTextDim).lineLimit(1)
            // VS Code: ● while unsaved, ✕ otherwise.
            Button { store.editor.requestClose(file.path) } label: {
                Image(systemName: file.isDirty ? "circle.fill" : "xmark")
                    .font(.system(size: file.isDirty ? 7 : 9, weight: .semibold)).foregroundStyle(Tokens.vsText)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(file.isDirty ? "Unsaved — ⌘S saves" : "Close")
        }
        .padding(.horizontal, 10)
        .frame(height: 35)
        .background(isActive ? Tokens.vsEditor : Tokens.vsTitle)
        .contentShape(Rectangle())
        .onTapGesture { store.editor.activate(file.path) }
        .help(file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        .contextMenu {
            Button("Close") { store.editor.requestClose(file.path) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: file.path)]) }
        }
    }
}

/// The editor's one web view, kept by `Editor` across view rebuilds.
private struct MonacoHost: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ web: WKWebView, context: Context) {}
}
