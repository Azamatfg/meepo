import SwiftUI

/// Project "…" → Check before done…: the command that proves a change works. Claude can't finish a turn that
/// changed files until it passes (Meepo's method, VERIFY).
struct CheckSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var command = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check before done").font(Fonts.ui(20, weight: .bold))
            Text("When Claude has changed files in \(project.name), it runs this before it finishes. If it fails, Claude reads the output and fixes it — you get a change that builds, not just \"done\".")
                .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            TextField("e.g. npm test, go build ./...", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(Fonts.mono(13))
                .focused($isFocused)
                .onSubmit(save)
            Text("Runs in the project folder with your shell. Keep it under a few minutes: it runs after every turn that changed something.")
                .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            HStack {
                if project.checkCommand != nil {
                    Button("Turn Off") { store.setCheck(project.id!, nil); dismiss() }.buttonStyle(PixelButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
                Button("Save", action: save).keyboardShortcut(.defaultAction).buttonStyle(PixelButtonStyle(isPrimary: true))
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
        .paperSheet()
        .task {
            command = project.checkCommand ?? ""
            isFocused = true
            guard command.isEmpty else { return }
            let found = await Task.detached(operation: { [path = project.path] in ProjectCheck.detect(in: path) }).value
            if command.isEmpty, let found { command = found } // typed meanwhile: theirs stays
        }
    }

    private func save() {
        store.setCheck(project.id!, command)
        dismiss()
    }
}
