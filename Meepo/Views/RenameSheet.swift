import SwiftUI

/// Names a session — in Meepo, and in Claude Code too (`/rename`) while it runs.
struct RenameSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: Session
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name this session").font(Fonts.ui(20, weight: .bold))
            Text("So it's easy to tell apart from other sessions in \(store.project(for: session)?.name ?? "this project").")
                .foregroundStyle(Tokens.textDim)
            TextField("e.g. refunds, bugfix login", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
                Button("Save", action: save).keyboardShortcut(.defaultAction).buttonStyle(PixelButtonStyle(isPrimary: true))
            }
        }
        .padding(22)
        .frame(width: 420)
        .paperSheet()
        .onAppear {
            name = session.name ?? ""
            isFocused = true
        }
    }

    private func save() {
        store.rename(session.id!, to: name)
        dismiss()
    }
}

/// Names a new tab group and puts the session in it; other sessions join it from their own Group menu.
struct GroupNameSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: Session
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New tab group").font(Fonts.ui(20, weight: .bold))
            Text("Sessions of any projects can be in it; add others from their tab's Group menu.")
                .foregroundStyle(Tokens.textDim)
            TextField("e.g. support, release", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
                Button("Create", action: save).keyboardShortcut(.defaultAction).buttonStyle(PixelButtonStyle(isPrimary: true))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .paperSheet()
        .onAppear { isFocused = true }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.setGroup(session.id!, to: name)
        dismiss()
    }
}

/// Names a new workspace and puts the project in it; other projects join it from their own Workspace menu.
struct WorkspaceNameSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New workspace").font(Fonts.ui(20, weight: .bold))
            Text("Where the work is: personal, a job, a client. The sidebar shows one workspace at a time, or all.")
                .foregroundStyle(Tokens.textDim)
            TextField("e.g. Personal, alva", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
                Button("Create", action: save).keyboardShortcut(.defaultAction).buttonStyle(PixelButtonStyle(isPrimary: true))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .paperSheet()
        .onAppear { isFocused = true }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.setWorkspace(project.id!, to: name)
        store.workspace = name.trimmingCharacters(in: .whitespaces) // see what was just made
        dismiss()
    }
}
