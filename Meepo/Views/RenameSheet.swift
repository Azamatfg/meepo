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
