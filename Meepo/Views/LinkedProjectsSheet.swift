import SwiftUI

/// "Linked Projects…": the projects that work together with this one (a backend and its app), and its contract
/// files — what they depend on. A session is told about its links; a change to a contract file offers to tell them.
struct LinkedProjectsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var linked: Set<Int64> = []
    @State private var contracts = ""
    @State private var suggestions: [String] = []

    var body: some View {
        let others = store.projects.filter { $0.id != project.id }
        VStack(alignment: .leading, spacing: 12) {
            Text("Linked projects of \(project.name)").font(Fonts.ui(20, weight: .bold))
            Text("Projects that work together, like a backend and its app. Their sessions know about each other, and when \(project.name) changes a contract file, meepo offers to tell them.")
                .foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(others) { other in
                        Toggle(isOn: Binding(get: { linked.contains(other.id!) },
                                             set: { if $0 { linked.insert(other.id!) } else { linked.remove(other.id!) } })) {
                            Text(other.name) + Text(other.workspace.map { "  · \($0)" } ?? "").foregroundStyle(Tokens.textDim)
                        }
                    }
                    if others.isEmpty { Text("Add another project to meepo first.").foregroundStyle(Tokens.textDim) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            Text("Contract files of \(project.name)").font(Fonts.ui(13, weight: .semibold))
            Text("What the linked projects depend on, one per line, relative to the project: api/openapi.yaml, proto/**, src/api/.")
                .font(.caption).foregroundStyle(Tokens.textDim).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $contracts).font(Fonts.mono(13)).frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Tokens.line))
            let lines = Set(contracts.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            let fresh = suggestions.filter { !lines.contains($0) }
            if !fresh.isEmpty {
                HStack(spacing: 6) {
                    Text("Found:").font(.caption).foregroundStyle(Tokens.textDim)
                    ForEach(fresh, id: \.self) { glob in
                        Button("+ \(glob)") { contracts += (contracts.isEmpty || contracts.hasSuffix("\n") ? "" : "\n") + glob }
                            .buttonStyle(PixelButtonStyle(compact: true))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PixelButtonStyle())
                Button("Save") {
                    store.setLinks(project.id!, linked: linked, contracts: contracts.split(separator: "\n").map(String.init))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(PixelButtonStyle(isPrimary: true))
            }
        }
        .padding(22)
        .frame(width: 500)
        .paperSheet()
        .task {
            linked = Set(project.linkedProjectIds ?? [])
            contracts = (project.contractPaths ?? []).joined(separator: "\n")
            let path = project.path
            suggestions = await Task.detached {
                Links.suggestions((GitService.output(["ls-files"], in: path) ?? "").split(separator: "\n").map(String.init))
            }.value
        }
    }
}
