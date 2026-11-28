import SwiftUI

/// The title bar's workspace switcher (2026-11-28): seen in every layout, Solo too — the sidebar's isn't.
struct WorkspaceChip: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Menu {
            Button(store.workspace == nil ? "✓ All projects" : "All projects") { store.workspace = nil }
            if !store.workspaceNames.isEmpty { Divider() }
            ForEach(store.workspaceNames, id: \.self) { name in
                let count = sessions(in: name), waiting = waiting(in: name)
                Button((name == store.workspace ? "✓ " : "") + name + (count > 0 ? "  ·  \(count) session\(count == 1 ? "" : "s")" : "")
                       + (waiting > 0 ? "  ·  \(waiting) need\(waiting == 1 ? "s" : "") you" : "")) {
                    store.workspace = name
                }
            }
            Divider()
            Button(store.workspaceNames.isEmpty ? "Set Up Workspaces…" : "Workspaces…") { store.isWorkspacesShown = true }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(store.workspace == nil ? Tokens.idle : Tokens.work).frame(width: 7, height: 7)
                Text(store.workspace ?? "All projects").font(Fonts.ui(13, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.textDim)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Tokens.ghost, in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Workspace: which projects the tabs and lists show")
    }

    private func waiting(in workspace: String) -> Int {
        let ids = Set(store.projects.filter { $0.workspace == workspace }.compactMap(\.id))
        return store.sessions.filter { ids.contains($0.projectId) && ($0.status == .waitingInput || $0.status == .waitingPermission) }.count
    }

    private func sessions(in workspace: String) -> Int {
        let ids = Set(store.projects.filter { $0.workspace == workspace }.compactMap(\.id))
        return store.sessions.filter { ids.contains($0.projectId) }.count
    }
}

/// Every workspace and every project on one screen: pick a workspace on the left, tick its projects on the right.
/// A suggestion from the projects' names (taxi, taxinet, taxi-kolesa → taxi) is one click.
struct WorkspacesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    /// Named but with no project yet: a workspace exists through its projects, so it waits here.
    @State private var drafts: [String] = []
    @State private var newName = ""
    @State private var rename = ""

    private var names: [String] { (store.workspaceNames + drafts.filter { !store.workspaceNames.contains($0) }).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Workspaces").font(Fonts.ui(22, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle(isPrimary: true))
            }
            Text("Group projects by where the work is — a job, a client, your own. The title bar shows one workspace at a time: its tabs, its projects.")
                .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            suggestions
            HStack(alignment: .top, spacing: 16) {
                list.frame(width: 210)
                Rectangle().fill(Tokens.line).frame(width: 1)
                projects.frame(maxWidth: .infinity)
            }
            .frame(minHeight: 380)
        }
        .padding(22)
        .frame(width: 720, height: 600)
        .paperSheet()
        .onAppear { selected = selected ?? store.workspace ?? names.first }
    }

    @ViewBuilder private var suggestions: some View {
        let offered = AppStore.suggestedWorkspaces(store.projects.filter { $0.workspace == nil }.map(\.name))
            .filter { !store.workspaceNames.contains($0.key) }
        if !offered.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Tokens.work)
                Text("Suggested: " + offered.keys.sorted().map { "\($0) (\(offered[$0]!.joined(separator: ", ")))" }.joined(separator: "; "))
                    .font(Fonts.ui(13)).lineLimit(2)
                Spacer()
                Button("APPLY") {
                    for (name, members) in offered {
                        for project in store.projects where members.contains(project.name) { store.setWorkspace(project.id!, to: name) }
                    }
                    selected = offered.keys.sorted().first
                }
                .buttonStyle(PixelButtonStyle(compact: true, isPrimary: true))
            }
            .padding(12)
            .background(Tokens.workTint, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(names, id: \.self) { name in
                Button { selected = name; rename = name } label: {
                    HStack {
                        Text(name).font(Fonts.ui(14, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Text("\(store.projects.filter { $0.workspace == name }.count)").font(Fonts.mono(12)).foregroundStyle(Tokens.textDim)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(selected == name ? Tokens.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            TextField("New workspace", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
                .padding(.top, 6)
            Text("Return to add, then tick its projects.").font(.caption).foregroundStyle(Tokens.textDim)
            Spacer()
        }
    }

    @ViewBuilder private var projects: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Name", text: $rename)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            store.renameWorkspace(selected, to: rename)
                            drafts = drafts.map { $0 == selected ? rename : $0 }
                            self.selected = rename.trimmingCharacters(in: .whitespaces)
                        }
                        .frame(maxWidth: 260)
                    Spacer()
                    Button("Remove") {
                        store.removeWorkspace(selected)
                        drafts.removeAll { $0 == selected }
                        self.selected = names.first
                    }
                    .buttonStyle(PixelButtonStyle(compact: true))
                    .help("The projects stay; only this grouping goes")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.projects) { project in
                            let isIn = project.workspace == selected
                            Button { store.setWorkspace(project.id!, to: isIn ? nil : selected) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isIn ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(isIn ? Tokens.work : Tokens.textDim)
                                    Text(project.name).font(Fonts.ui(14))
                                    if let other = project.workspace, other != selected {
                                        Text("in \(other)").font(.caption).foregroundStyle(Tokens.textDim)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(isIn ? "Take \(project.name) out of \(selected)" : "Move \(project.name) into \(selected)")
                        }
                    }
                }
            }
            .onAppear { rename = selected }
        } else {
            Text("Add a workspace on the left — or apply the suggestion above.").foregroundStyle(Tokens.textDim)
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !names.contains(name) { drafts.append(name) }
        selected = name
        rename = name
        newName = ""
    }
}
