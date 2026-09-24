import SwiftUI

struct NewSessionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var projectId: Int64?
    @State private var model = ""
    @State private var prompt = ""
    @State private var error: String?
    @State private var useWorktree = false
    @State private var featureName = ""


    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NEW SESSION").font(Fonts.title(18)).foregroundStyle(Tokens.text)
            FieldRow("Project") {
                PixelMenu(selection: store.projects.first { $0.id == projectId }?.name ?? "—") {
                    ForEach(store.projects) { project in
                        Button(project.name) { projectId = project.id }
                    }
                }
            }
            FieldRow("Worktree") {
                Button(useWorktree ? "ON" : "OFF") { useWorktree.toggle() }
                    .buttonStyle(PixelButtonStyle())
                    .disabled(!isGit)
                    .overlay { if useWorktree { Rectangle().stroke(Tokens.selection, lineWidth: 2) } }
                    .help("Separate git worktree and branch (claude -w), so parallel features don't touch each other's files")
            }
            if useWorktree {
                TextField("Feature name, e.g. login-google", text: $featureName)
                    .textFieldStyle(.plain)
                    .font(Fonts.mono(13))
                    .foregroundStyle(Tokens.text)
                    .padding(6)
                    .background(Tokens.terminalBg)
                    .sunken()
            }
            FieldRow("Model") {
                PixelMenu(selection: store.modelChoices().first { $0.value == model }?.title ?? model) {
                    ForEach(store.modelChoices(), id: \.value) { option in
                        Button(option.title) { model = option.value }
                    }
                }
            }
            Text("First prompt (optional)").font(.caption).foregroundStyle(Tokens.textDim)
            TextEditor(text: $prompt)
                .font(Fonts.mono(13))
                .foregroundStyle(Tokens.text)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 110)
                .background(Tokens.terminalBg)
                .sunken()
            if let error {
                Text(error).foregroundStyle(Tokens.danger)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(projectId == nil || (useWorktree && ClaudeLauncher.worktreeSlug(featureName).isEmpty))
            }
            .buttonStyle(PixelButtonStyle())
        }
        .padding(16)
        .frame(width: 460)
        .background(Tokens.grass)
        .pixelFrame(6)
        .preferredColorScheme(.dark)
        .onAppear { projectId = store.newSessionProjectId }
        // SPEC module 5: a second session in the same project defaults to its own worktree.
        .onChange(of: projectId, initial: true) {
            useWorktree = isGit && store.sessions.contains { $0.projectId == projectId }
        }
    }

    /// Worktrees need git; a plain folder project runs sessions in the folder itself.
    private var isGit: Bool {
        guard let path = store.projects.first(where: { $0.id == projectId })?.path else { return false }
        return GitService.output(["rev-parse", "--is-inside-work-tree"], in: path) == "true"
    }

    private func create() {
        guard let projectId else { return }
        do {
            try store.createSession(projectId: projectId, model: model.isEmpty ? nil : model,
                                    prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                    worktree: useWorktree ? featureName : nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Label on the left, control on the right.
struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Tokens.text)
            Spacer()
            content
        }
    }
}

/// Drop-down in the pixel button look instead of the system pop-up.
struct PixelMenu<Items: View>: View {
    let selection: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 6) {
                Text(selection)
                Text("▾")
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PixelButtonStyle())
        .fixedSize()
    }
}
