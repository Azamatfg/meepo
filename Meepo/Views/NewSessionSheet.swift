import SwiftUI

struct NewSessionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var projectId: Int64?
    @State private var model = ""
    @State private var prompt = ""
    @State private var error: String?

    /// Aliases accepted by `claude --model`; empty = Claude Code's default.
    private let models = [("", "По умолчанию"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]

    var body: some View {
        Form {
            Picker("Проект", selection: $projectId) {
                ForEach(store.projects) { Text($0.name).tag($0.id) }
            }
            Picker("Модель", selection: $model) {
                ForEach(models, id: \.0) { Text($0.1).tag($0.0) }
            }
            TextField("Первый промпт (необязательно)", text: $prompt, axis: .vertical)
                .lineLimit(3...8)
            if let error {
                Text(error).foregroundStyle(Tokens.fire)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Запустить") { create() }
                    .disabled(projectId == nil)
            }
        }
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
