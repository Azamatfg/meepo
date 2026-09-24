import SwiftUI

/// Moving over from VS Code / Cursor / Windsurf (SPEC module 13): pick recent repos, optionally continue each
/// project's latest Claude conversation in Meepo (`--resume`).
struct ImportView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("IMPORT FROM IDE").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .buttonStyle(PixelButtonStyle())
            ImportList { dismiss() }
        }
        .padding(16)
        .frame(width: 760, height: 600)
        .background(Tokens.grass)
        .pixelFrame(6)
        .preferredColorScheme(.dark)
    }
}

/// Also the last step of onboarding.
struct ImportList: View {
    @Environment(AppStore.self) private var store
    let onDone: () -> Void
    @State private var rows: [Row]?
    @State private var picked: Set<String> = []
    @State private var resumed: Set<String> = []

    struct Row: Identifiable {
        let folder: IDEImport.Folder
        let session: IDEImport.ClaudeSession?
        var id: String { folder.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let rows, rows.isEmpty {
                        Text("No git repositories in VS Code, Cursor or Windsurf history that aren't in Meepo yet.")
                            .foregroundStyle(Tokens.textDim)
                    } else if rows == nil {
                        Text("Looking through IDE history…").foregroundStyle(Tokens.textDim)
                    }
                    ForEach(rows ?? []) { row in
                        RowView(row: row, isPicked: bind(row.id, in: $picked), isResumed: bind(row.id, in: $resumed))
                    }
                }
                .padding(6)
            }
            .background(Tokens.dirt)
            .sunken()
            HStack {
                Text("Open windows are listed first. A conversation continues where it stopped (claude --resume).")
                    .font(.caption).foregroundStyle(Tokens.textDim)
                Spacer()
                Button("IMPORT \(picked.count)") { importPicked() }
                    .buttonStyle(PixelButtonStyle())
                    .disabled(picked.isEmpty)
            }
        }
        .task {
            let skip = Set(store.projects.map(\.path))
            let found = await Task.detached {
                IDEImport.recentFolders(skip: skip).prefix(60).map { Row(folder: $0, session: IDEImport.latestClaudeSession(for: $0.path)) }
            }.value
            rows = found
            picked = Set(found.filter(\.folder.isOpen).map(\.id))
            resumed = Set(found.filter { $0.folder.isOpen && $0.session != nil }.map(\.id))
        }
    }

    private func bind(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) },
                set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }

    private func importPicked() {
        for row in rows ?? [] where picked.contains(row.id) {
            do {
                try store.addProject(at: URL(filePath: row.folder.path))
            } catch {
                store.bridgeError = error.localizedDescription
                continue
            }
            guard resumed.contains(row.id), let session = row.session,
                  let projectId = store.projects.first(where: { $0.path == row.folder.path })?.id else { continue }
            try? store.createSession(projectId: projectId, model: nil, prompt: nil, resuming: session.id)
        }
        onDone()
    }
}

private struct RowView: View {
    let row: ImportList.Row
    @Binding var isPicked: Bool
    @Binding var isResumed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                check(isPicked) { isPicked.toggle() }
                Text(URL(filePath: row.folder.path).lastPathComponent).foregroundStyle(Tokens.text)
                if row.folder.isOpen { Text("OPEN").font(.caption2).foregroundStyle(Tokens.selection) }
                Text(row.folder.ides.joined(separator: " · ")).font(.caption).foregroundStyle(Tokens.textDim)
                Spacer()
                Text(row.folder.lastUsed.formatted(.relative(presentation: .named)))
                    .font(.caption).foregroundStyle(Tokens.textDim)
            }
            Text(row.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(Fonts.mono(11)).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.middle)
                .padding(.leading, 28)
            if let session = row.session, isPicked {
                HStack(spacing: 8) {
                    check(isResumed) { isResumed.toggle() }
                    Text("Continue “\(session.title)” · \(session.date.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(Tokens.screen).lineLimit(1)
                }
                .padding(.leading, 28)
            }
        }
        .padding(4)
    }

    private func check(_ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(on ? "[x]" : "[ ]").font(Fonts.mono(13)).foregroundStyle(on ? Tokens.selection : Tokens.textDim)
        }
        .buttonStyle(.plain)
    }
}
