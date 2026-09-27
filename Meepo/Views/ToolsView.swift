import SwiftUI

/// TOOLS sheet (SPEC module 11): Docker upkeep, ports, and every change meepo made to your files.
/// No shared-commands library: Claude Code already gives one command to every project through ~/.claude.
struct ToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.docker
    @State private var confirmation: PixelConfirmation?

    enum Tab: String, CaseIterable { case docker = "DOCKER", ports = "PORTS", changes = "CHANGES" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TOOLS").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                ForEach(Tab.allCases, id: \.self) { item in
                    Button(item.rawValue) { tab = item }
                        .overlay { if tab == item { Bevel(raised: false) } }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(confirmation == nil ? .cancelAction : nil)
            }
            .buttonStyle(PixelButtonStyle())
            switch tab {
            case .docker: DockerView(confirmation: $confirmation)
            case .ports: PortsView(confirmation: $confirmation)
            case .changes: ChangesView(confirmation: $confirmation)
            }
        }
        .padding(16)
        .frame(width: 760, height: 600)
        .background(Tokens.grass)
        .pixelFrame(6)
        .pixelConfirm($confirmation)
        .preferredColorScheme(.light)
    }
}

/// DOCKER: where Docker's space went, one Clear for what nothing uses, and each project's saved data — Delete only
/// for a volume no container uses, always asked first.
private struct DockerView: View {
    @Environment(AppStore.self) private var store
    @Binding var confirmation: PixelConfirmation?
    @State private var space: Docker.Space?
    @State private var state = "Looking at Docker…"
    @State private var note: String?
    @State private var isBusy = false
    @State private var isClearing = false
    @State private var unfolded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let space {
                Text(Explain.dockerSpace(Docker.size(space.total))).font(Fonts.ui(13)).foregroundStyle(Tokens.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                if let note { Text(note).font(Fonts.ui(13, weight: .semibold)).foregroundStyle(Tokens.text) }
                safeToClear(space)
                savedData(space)
            } else {
                Text(state).foregroundStyle(Tokens.textDim)
                Spacer()
            }
        }
        .task { await load() }
    }

    private func safeToClear(_ space: Docker.Space) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SAFE TO CLEAR").font(Fonts.title(14)).foregroundStyle(Tokens.text)
                Spacer()
                Button(isClearing ? "Clearing…" : "Clear ≈\(Docker.size(space.safeBytes))…") { confirmClear(space) }
                    .buttonStyle(PixelButtonStyle(isPrimary: true))
                    .disabled(space.clearCommands.isEmpty || isBusy)
                    .help(space.clearCommands.map { "docker " + command($0) }.joined(separator: "\n"))
            }
            if space.clearCommands.isEmpty {
                Text("Nothing to clear: every image and volume is in use or holds a project's data.").font(.caption).foregroundStyle(Tokens.textDim)
            }
            if !space.unusedImages.isEmpty {
                line("\(space.unusedImages.count) images no container uses", "≈\(Docker.size(space.imagesBytes))",
                     "Docker downloads or builds one again when a project needs it.")
            }
            if !space.leftoverVolumes.isEmpty {
                line("\(space.leftoverVolumes.count) unnamed volumes", Docker.size(space.leftoverBytes),
                     "Left behind by containers that are gone; nothing uses them.")
            }
            if space.buildCacheBytes > 0 {
                line("Build cache", Docker.size(space.buildCacheBytes), "Leftovers of building images; the next build takes a bit longer.")
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Tokens.dirt).sunken()
    }

    private func line(_ what: String, _ size: String, _ why: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(size).font(Fonts.mono(12)).foregroundStyle(Tokens.text).frame(width: 80, alignment: .leading)
            Text(what).foregroundStyle(Tokens.text)
            Text(why).font(.caption).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.tail)
        }
    }

    private func savedData(_ space: Docker.Space) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("PROJECTS' SAVED DATA").font(Fonts.title(14)).foregroundStyle(Tokens.text)
                Text(Docker.size(space.owners.reduce(0) { $0 + $1.bytes })).font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
            }
            Text("Databases and files your projects' containers keep between restarts (volumes). Not junk — meepo never clears them in bulk. Delete is there only for a volume no container uses, and it can't be undone.")
                .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if space.owners.isEmpty { Text("No saved data.").foregroundStyle(Tokens.textDim) }
                    ForEach(space.owners) { owner in
                        let isOpen = unfolded.contains(owner.id)
                        Button {
                            if isOpen { unfolded.remove(owner.id) } else { unfolded.insert(owner.id) }
                        } label: {
                            HStack(spacing: 8) {
                                Text(isOpen ? "▾" : "▸").font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
                                Text(owner.title).foregroundStyle(owner.isProject ? Tokens.text : Tokens.textDim).lineLimit(1)
                                Spacer()
                                Text(inUse(owner)).font(.caption).foregroundStyle(Tokens.textDim)
                                Text(Docker.size(owner.bytes)).font(Fonts.mono(12)).foregroundStyle(Tokens.text)
                                    .frame(width: 80, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if isOpen {
                            ForEach(owner.volumes) { volume in volumeRow(volume, of: owner, space) }
                        }
                    }
                }
                .padding(8)
            }
            .background(Tokens.dirt)
            .sunken()
        }
    }

    private func inUse(_ owner: Docker.Owner) -> String {
        let used = owner.volumes.filter { Docker.deleteArgs(for: $0) == nil }.count
        let count = owner.volumes.count == 1 ? "1 volume" : "\(owner.volumes.count) volumes"
        return used == 0 ? "\(count), none in use" : used == owner.volumes.count ? "\(count), in use" : "\(count), \(used) in use"
    }

    private func volumeRow(_ volume: Docker.Volume, of owner: Docker.Owner, _ space: Docker.Space) -> some View {
        HStack(spacing: 8) {
            Text(volume.isAnonymous ? "unnamed · \(volume.name.prefix(12))" : volume.name)
                .font(Fonts.mono(11)).foregroundStyle(Tokens.text).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let users = space.usedBy[volume.name] {
                Text("used by \(users.joined(separator: ", "))").font(.caption).foregroundStyle(Tokens.textDim).lineLimit(1)
            }
            Text(Docker.size(volume.bytes)).font(Fonts.mono(11)).foregroundStyle(Tokens.textDim).frame(width: 70, alignment: .trailing)
            if let args = Docker.deleteArgs(for: volume) {
                Button("Delete…") { confirmDelete(volume, args: args, of: owner) }
                    .buttonStyle(PixelButtonStyle(compact: true))
                    .disabled(isBusy)
                    .help("docker " + args.joined(separator: " "))
            } else if space.usedBy[volume.name] == nil {
                Text("in use").font(.caption).foregroundStyle(Tokens.textDim)
            }
        }
        .padding(.leading, 20)
        .help(volume.name)
    }

    /// "volume rm 2ed076b31423… (18 volumes)" — the hashes say nothing.
    private func command(_ args: [String]) -> String {
        args.count > 4 && args[0] == "volume" ? "volume rm \(args[2].prefix(12))… (\(args.count - 2) volumes)" : args.joined(separator: " ")
    }

    private func confirmClear(_ space: Docker.Space) {
        var items: [String] = []
        if !space.unusedImages.isEmpty {
            let names = space.unusedImages.prefix(3).joined(separator: ", ") + (space.unusedImages.count > 3 ? ", …" : "")
            items.append("• \(space.unusedImages.count) images no container uses, ≈\(Docker.size(space.imagesBytes)) (\(names)). Docker downloads or builds one again when a project needs it.")
        }
        if !space.leftoverVolumes.isEmpty {
            items.append("• \(space.leftoverVolumes.count) unnamed volumes nothing uses, \(Docker.size(space.leftoverBytes)) — left behind by containers that are gone.")
        }
        if space.buildCacheBytes > 0 { items.append("• Build cache, \(Docker.size(space.buildCacheBytes)) — the next build takes a bit longer.") }
        confirmation = PixelConfirmation(
            title: "Clear ≈\(Docker.size(space.safeBytes))?",
            message: (items + ["Projects' saved data and anything a container uses stay."]).joined(separator: "\n"),
            action: "Clear"
        ) { Task { await clear(space) } }
    }

    private func confirmDelete(_ volume: Docker.Volume, args: [String], of owner: Docker.Owner) {
        confirmation = PixelConfirmation(
            title: "Delete \(volume.isAnonymous ? "this unnamed volume" : volume.name)?",
            message: "Saved data of \(owner.title), \(Docker.size(volume.bytes)) — a database or files its containers kept. No container uses it now. It can't be undone: the next start begins with this data empty.",
            action: "Delete"
        ) {
            Task {
                guard let docker = store.toolPath("docker"), let before = space?.total else { return }
                isBusy = true
                note = nil
                let done = await Task.detached { Docker.run(docker, args) != nil }.value
                await load()
                isBusy = false
                let name = volume.isAnonymous ? "the unnamed volume" : volume.name
                note = done ? "Deleted \(name) — freed \(Docker.size(max(before - (space?.total ?? before), 0)))."
                    : "Docker didn't delete \(name) — a container may be using it now."
            }
        }
    }

    private func load() async {
        guard let docker = store.toolPath("docker") else { state = "Docker isn't installed — nothing to clean up here."; return }
        let projects = store.projects
        let result = await Task.detached { () -> Docker.Space? in
            guard let summary = Docker.run(docker, ["system", "df", "--format", "{{json .}}"]),
                  let verbose = Docker.run(docker, ["system", "df", "-v", "--format", "{{json .}}"]) else { return nil }
            return Docker.space(summary: summary, verbose: verbose, projects: projects)
        }.value
        guard let result else { space = nil; state = "Docker isn't running. Start Docker Desktop to see where its space went."; return }
        space = result
    }

    private func clear(_ cleared: Docker.Space) async {
        guard let docker = store.toolPath("docker") else { return }
        isBusy = true
        isClearing = true
        note = nil
        let failed = await Task.detached {
            cleared.clearCommands.filter { Docker.run(docker, $0) == nil }.count
        }.value
        await load()
        isBusy = false
        isClearing = false
        let freed = Docker.size(max(cleared.total - (space?.total ?? cleared.total), 0))
        note = failed == 0 ? "Freed \(freed)." : "Freed \(freed). Docker couldn't clear everything — something may have started using it."
    }
}

/// Every change Meepo made to the user's files (SPEC §8), newest first, each with RESTORE.
private struct ChangesView: View {
    @Environment(AppStore.self) private var store
    @Binding var confirmation: PixelConfirmation?
    @State private var entries: [ChangeLog.Entry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if entries.isEmpty { Text("meepo hasn't changed any of your files yet.").foregroundStyle(Tokens.textDim) }
                    ForEach(entries) { entry in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.action).foregroundStyle(Tokens.text)
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(Tokens.textDim)
                                }
                                Text(entry.file.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(Fonts.mono(11)).foregroundStyle(Tokens.textDim).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("RESTORE") {
                                confirmation = PixelConfirmation(
                                    title: "RESTORE \(URL(filePath: entry.file).lastPathComponent.uppercased())?",
                                    message: entry.backup == nil
                                        ? "meepo created this; restoring moves it to the Trash."
                                        : "Puts back the file as it was before “\(entry.action)”. The current file is backed up first.",
                                    action: "RESTORE"
                                ) { restore(entry) }
                            }
                            .buttonStyle(PixelButtonStyle())
                        }
                        .padding(6)
                        .help(entry.file)
                    }
                }
                .padding(6)
            }
            .background(Tokens.dirt)
            .sunken()
            Text("Backups and this log: ~/.meepo/backups").font(.caption).foregroundStyle(Tokens.textDim)
        }
        .onAppear(perform: reload)
    }

    private func reload() { entries = ChangeLog.entries(backups: store.backupsDir) }

    private func restore(_ entry: ChangeLog.Entry) {
        let backups = store.backupsDir
        Task {
            // Off the main thread: a backup copies whole folders.
            let failure = await Task.detached { () -> String? in
                do { try ChangeLog.restore(entry, backups: backups); return nil } catch { return error.localizedDescription }
            }.value
            if let failure { store.bridgeError = failure }
            reload()
            store.refreshProjects()
        }
    }
}
