import SwiftUI

/// One file to compare: its row in the file list and how to read both versions (lazily, off the main thread).
struct DiffSource: Identifiable {
    let id: String
    let status: String
    var added: Int?
    var removed: Int?
    var isUncommitted = false
    let load: @Sendable () -> (old: Data?, new: Data?)
}

/// The compare view, one-to-one with VS Code: the changed files as in Source Control on the left, VS Code's own
/// diff editor (Monaco) on the right — side by side or inline, ⌥↑ / ⌥↓ between changes.
struct DiffViewer: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let sources: [DiffSource]
    @State var selected: String
    @State private var content = MonacoDiffView.Content(message: "Loading…")
    @State private var navigation = MonacoDiffView.Navigation()
    @State private var changeCount = 0
    @AppStorage("diffInline") private var inline = false

    var body: some View {
        HStack(spacing: 0) {
            if sources.count > 1 {
                fileList.frame(width: 260)
                Rectangle().fill(Tokens.vsBorder).frame(width: 1)
            }
            VStack(spacing: 0) {
                tabBar
                MonacoDiffView(content: content, sideBySide: !inline, navigation: navigation) { changeCount = $0 }
            }
        }
        .frame(minWidth: 900, idealWidth: 1200, minHeight: 600, idealHeight: 780)
        .background(Tokens.vsEditor)
        .preferredColorScheme(.dark)
        .task(id: selected) { await load() }
    }

    // MARK: VS Code's editor title: file, where the two sides come from, actions on the right

    private var tabBar: some View {
        let source = sources.first { $0.id == selected }
        return HStack(spacing: 10) {
            Text(URL(filePath: selected).lastPathComponent).font(.system(size: 13)).foregroundStyle(Tokens.vsText)
            Text("(\(title))").font(.system(size: 12)).foregroundStyle(Tokens.vsTextDim)
            if let added = source?.added, added > 0 { Text("+\(added)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Tokens.vsAdded) }
            if let removed = source?.removed, removed > 0 { Text("−\(removed)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Tokens.vsDeleted) }
            Spacer()
            if changeCount > 0 {
                Text("\(changeCount) change\(changeCount == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(Tokens.vsTextDim)
            }
            iconButton("arrow.up", help: "Previous change (⌥↑)", key: .upArrow) { go("previous") }
            iconButton("arrow.down", help: "Next change (⌥↓)", key: .downArrow) { go("next") }
            iconButton(inline ? "rectangle.split.2x1" : "rectangle", help: inline ? "Side by side" : "Inline") { inline.toggle() }
            iconButton("xmark", help: "Close (Esc)", key: .escape, modifiers: []) { dismiss() }
        }
        .padding(.horizontal, 12)
        .frame(height: 35)
        .background(Tokens.vsTitle)
    }

    @ViewBuilder
    private func iconButton(_ symbol: String, help: String, key: KeyEquivalent? = nil,
                            modifiers: EventModifiers = .option, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Tokens.vsText).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
        if let key { button.keyboardShortcut(key, modifiers: modifiers) } else { button }
    }

    private func go(_ direction: String) {
        navigation = MonacoDiffView.Navigation(step: navigation.step + 1, direction: direction)
    }

    // MARK: Source Control–style file list

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CHANGES").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.vsTextDim)
                .padding(.horizontal, 12).frame(height: 35, alignment: .leading)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sources) { source in
                        Button { selected = source.id } label: {
                            HStack(spacing: 6) {
                                Text(URL(filePath: source.id).lastPathComponent).font(.system(size: 13))
                                    .foregroundStyle(source.status == "D" ? Tokens.vsTextDim : Tokens.vsText)
                                    .strikethrough(source.status == "D")
                                    .lineLimit(1)
                                Text((source.id as NSString).deletingLastPathComponent).font(.system(size: 12))
                                    .foregroundStyle(Tokens.vsTextDim).lineLimit(1).truncationMode(.head)
                                Spacer(minLength: 4)
                                Text(Self.letter(source.status)).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Self.color(source.status))
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 22)
                            .background(source.id == selected ? Tokens.vsListActive : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(source.id + (source.isUncommitted ? " — not committed yet" : ""))
                    }
                }
            }
        }
        .background(Tokens.vsSideBar)
    }

    /// VS Code's letters: U untracked, A added, M modified, D deleted, R renamed.
    static func letter(_ status: String) -> String { status == "?" ? "U" : status }

    static func color(_ status: String) -> Color {
        switch status {
        case "A", "?": Tokens.vsAdded
        case "D": Tokens.vsDeleted
        default: Tokens.vsModified
        }
    }

    // MARK: Loading

    private func load() async {
        guard let source = sources.first(where: { $0.id == selected }) else { return }
        changeCount = 0
        let (old, new) = await Task.detached { source.load() }.value
        if Self.isBinary(old ?? Data()) || Self.isBinary(new ?? Data()) {
            content = MonacoDiffView.Content(path: selected, message: "Binary file — not shown.")
            return
        }
        content = MonacoDiffView.Content(original: String(decoding: old ?? Data(), as: UTF8.self),
                                         modified: String(decoding: new ?? Data(), as: UTF8.self), path: selected)
    }

    /// A NUL byte in the first 8 KB: binary, like git decides.
    static func isBinary(_ data: Data) -> Bool { data.prefix(8000).contains(0) }
}
