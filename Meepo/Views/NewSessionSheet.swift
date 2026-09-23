import SwiftUI

struct NewSessionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var projectId: Int64?
    @State private var model = ""
    @State private var prompt = ""
    @State private var error: String?

    /// Aliases accepted by `claude --model`; empty = Claude Code's default.
    private let models = [("", "Default"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]

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
            FieldRow("Model") {
                PixelMenu(selection: models.first { $0.0 == model }?.1 ?? "Default") {
                    ForEach(models, id: \.0) { option in
                        Button(option.1) { model = option.0 }
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
                    .disabled(projectId == nil)
            }
            .buttonStyle(PixelButtonStyle())
        }
        .padding(16)
        .frame(width: 460)
        .background(Tokens.grass)
        .pixelFrame(6)
        .preferredColorScheme(.dark)
        .onAppear { projectId = store.newSessionProjectId }
    }

    private func create() {
        guard let projectId else { return }
        do {
            try store.createSession(projectId: projectId, model: model.isEmpty ? nil : model,
                                    prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
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
