import SwiftUI

/// Importing projects (SPEC module 13): every folder Claude Code has worked in, from any editor or terminal,
/// with its latest conversation to continue in Meepo (`--resume`).
struct ImportView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("IMPORT FROM CLAUDE CODE").font(Fonts.title(18)).foregroundStyle(Tokens.text)
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
        .preferredColorScheme(.light)
    }
}

/// Also the last step of onboarding.
struct ImportList: View {
    @Environment(AppStore.self) private var store
    let onDone: () -> Void
    @State private var folders: [ClaudeImport.Folder]?
    @State private var picked: Set<String> = []
    @State private var resumed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let folders, folders.isEmpty {
                        Text("Every folder Claude Code has worked in is already in meepo.").foregroundStyle(Tokens.textDim)
                    } else if folders == nil {
                        Text("Reading Claude Code's history…").foregroundStyle(Tokens.textDim)
                    }
                    ForEach(folders ?? []) { folder in
                        RowView(folder: folder, isPicked: bind(folder.id, in: $picked), isResumed: bind(folder.id, in: $resumed))
                    }
                }
                .padding(6)
            }
            .background(Tokens.dirt)
            .sunken()
            HStack {
                Text("Folders Claude Code worked in — from any editor or terminal. A conversation continues where it stopped.")
                    .font(.caption).foregroundStyle(Tokens.textDim)
                Spacer()
                Button("IMPORT \(picked.count)") { importPicked() }
                    .buttonStyle(PixelButtonStyle())
                    .disabled(picked.isEmpty)
            }
        }
        .task {
            let skip = Set(store.projects.map(\.path))
            let found = await Task.detached { ClaudeImport.folders(skip: skip) }.value
            folders = found
            // Pre-pick what was used in the last two weeks.
            let recent = found.filter { ($0.lastUsed ?? .distantPast) > .now.addingTimeInterval(-14 * 86_400) }
            picked = Set(recent.map(\.id))
            resumed = Set(recent.filter { $0.session != nil }.map(\.id))
        }
    }

    private func bind(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) },
                set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }

    private func importPicked() {
        for folder in folders ?? [] where picked.contains(folder.id) {
            do {
                try store.addProject(at: URL(filePath: folder.path))
            } catch {
                store.bridgeError = error.localizedDescription
                continue
            }
            guard resumed.contains(folder.id), let session = folder.session,
                  let projectId = store.projects.first(where: { $0.path == folder.path })?.id else { continue }
            try? store.createSession(projectId: projectId, model: nil, prompt: nil, resuming: session.id)
        }
        onDone()
    }
}

private struct RowView: View {
    let folder: ClaudeImport.Folder
    @Binding var isPicked: Bool
    @Binding var isResumed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                check(isPicked) { isPicked.toggle() }
                Text(URL(filePath: folder.path).lastPathComponent).foregroundStyle(Tokens.text)
                if !folder.isGit {
                    Text("NO GIT").font(.caption2).foregroundStyle(Tokens.warn)
                        .help("Not a git repository: sessions work, git features stay off until you run git init")
                }
                Spacer()
                Text(folder.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "long ago")
                    .font(.caption).foregroundStyle(Tokens.textDim)
            }
            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(Fonts.mono(11)).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.middle)
                .padding(.leading, 28)
            if let session = folder.session, isPicked {
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
