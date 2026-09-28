import SwiftUI

/// Importing projects (SPEC module 13): every folder Claude Code has worked in, from any editor or terminal,
/// with its latest conversation to continue in Meepo (`--resume`).
struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var picks = ImportPicks()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("IMPORT FROM CLAUDE CODE").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .buttonStyle(PixelButtonStyle())
            ImportList(picks: $picks) { dismiss() }
        }
        .padding(16)
        .frame(width: 760, height: 600)
        .background(Tokens.grass)
        .pixelFrame(6)
        .preferredColorScheme(.light)
    }
}

/// The folders on offer and which of them (and of their conversations) are picked.
struct ImportPicks {
    var folders: [ClaudeImport.Folder]?
    var picked: Set<String> = []
    var resumed: Set<String> = []
}

/// Also step 3 of onboarding, whose Open meepo imports the same picks: the caller keeps them.
struct ImportList: View {
    @Environment(AppStore.self) private var store
    @Binding var picks: ImportPicks
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let folders = picks.folders, folders.isEmpty {
                        Text("Every folder Claude Code has worked in is already in meepo.").foregroundStyle(Tokens.textDim)
                    } else if picks.folders == nil {
                        Text("Reading Claude Code's history…").foregroundStyle(Tokens.textDim)
                    }
                    ForEach(picks.folders ?? []) { folder in
                        RowView(folder: folder, isPicked: bind(folder.id, in: $picks.picked), isResumed: bind(folder.id, in: $picks.resumed))
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
                Button("IMPORT \(picks.picked.count)") { store.importPicked(&picks); onDone() }
                    .buttonStyle(PixelButtonStyle())
                    .disabled(picks.picked.isEmpty)
            }
        }
        .task {
            guard picks.folders == nil else { return } // read once: picks made since stay
            let skip = Set(store.projects.map(\.path))
            let found = await Task.detached { ClaudeImport.folders(skip: skip) }.value
            picks.folders = found
            // Pre-pick what was used in the last two weeks.
            let recent = found.filter { ($0.lastUsed ?? .distantPast) > .now.addingTimeInterval(-14 * 86_400) }
            picks.picked = Set(recent.map(\.id))
            picks.resumed = Set(recent.filter { $0.session != nil }.map(\.id))
        }
    }

    private func bind(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) },
                set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }
}

extension AppStore {
    /// Adds the picked folders, continuing the picked conversations, and takes what's in meepo now off the list:
    /// IMPORT, then onboarding's Open meepo, adds nothing twice.
    func importPicked(_ picks: inout ImportPicks) {
        var done: Set<String> = []
        for folder in picks.folders ?? [] where picks.picked.contains(folder.id) {
            do {
                try addProject(at: URL(filePath: folder.path))
            } catch AddProjectError.alreadyAdded {
                done.insert(folder.id) // already in meepo, with its sessions: not an error, and no second resume
                continue
            } catch {
                bridgeError = error.localizedDescription
                continue
            }
            done.insert(folder.id)
            guard picks.resumed.contains(folder.id), let session = folder.session,
                  let projectId = projects.first(where: { $0.path == folder.path })?.id else { continue }
            try? createSession(projectId: projectId, model: nil, prompt: nil, resuming: session.id)
        }
        picks.folders?.removeAll { done.contains($0.id) }
        picks.picked.subtract(done)
        picks.resumed.subtract(done)
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
