import SwiftUI

/// NOTES sheet (SPEC module 12): release note drafts per project, written on NEW, and the sample posts
/// that set their voice. Text leaves Meepo only by COPY / SHARE.
struct NotesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.drafts
    @State private var confirmation: PixelConfirmation?

    enum Tab: String, CaseIterable { case drafts = "DRAFTS", style = "STYLE" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("NOTES").font(Fonts.title(18)).foregroundStyle(Tokens.text)
                ForEach(Tab.allCases, id: \.self) { item in
                    Button(item.rawValue) { tab = item }
                        .overlay { if tab == item { Bevel(raised: false) } }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(confirmation == nil ? .cancelAction : nil)
            }
            .buttonStyle(PixelButtonStyle())
            switch tab {
            case .drafts: DraftsView(confirmation: $confirmation)
            case .style: StyleView()
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

private struct DraftsView: View {
    @Environment(AppStore.self) private var store
    @Binding var confirmation: PixelConfirmation?
    @State private var projectId: Int64?
    @State private var noteId: Int64?
    /// The note on screen has unsaved edits: a finished NEW must not swap it away.
    @State private var isDirty = false

    var body: some View {
        let project = store.projects.first { $0.id == projectId } ?? store.projects.first
        let notes = store.releaseNotes.filter { $0.projectId == project?.id }
        let note = notes.first { $0.id == noteId } ?? notes.first
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PixelMenu(selection: project?.name ?? "No projects") {
                    ForEach(store.projects) { item in Button(item.name) { projectId = item.id; noteId = nil } }
                }
                if let project {
                    let isWriting = store.writingNotes.contains(project.id!)
                    Button(isWriting ? "WRITING…" : "NEW") {
                        let shown = note?.id, newestBefore = notes.first?.id
                        noteId = shown // the new note becoming notes.first must not swap the note on screen
                        Task {
                            await store.writeReleaseNote(for: project)
                            let newest = store.releaseNotes.first { $0.projectId == project.id }?.id
                            // Show it only if one arrived and the user is still on the same note, with nothing unsaved.
                            if newest != newestBefore, noteId == shown, !isDirty { noteId = newest }
                        }
                    }
                    .disabled(isWriting)
                    .help("Draft a note about the commits since the last one, in the voice of STYLE")
                }
                if notes.count > 1, let note {
                    PixelMenu(selection: Self.title(note)) {
                        ForEach(notes) { item in Button(Self.title(item)) { noteId = item.id } }
                    }
                }
                Spacer()
            }
            .buttonStyle(PixelButtonStyle())
            if let note {
                NoteEditor(note: note, confirmation: $confirmation, isDirty: $isDirty).id(note.id)
            } else {
                Text("No notes yet. NEW writes one from the commits (and the last /ship report).")
                    .foregroundStyle(Tokens.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                    .background(Tokens.dirt)
                    .sunken()
            }
        }
    }

    private static func title(_ note: ReleaseNote) -> String {
        note.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// The note as it will read once pasted (bold, lists); EDIT shows its Markdown.
private struct NoteEditor: View {
    @Environment(AppStore.self) private var store
    let note: ReleaseNote
    @Binding var confirmation: PixelConfirmation?
    @Binding var isDirty: Bool
    @State private var text = ""
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("up to \(note.sha.prefix(7))").font(Fonts.mono(11)).foregroundStyle(Tokens.textDim)
                Spacer()
                if text != note.text {
                    Button("SAVE") { var edited = note; edited.text = text; store.updateReleaseNote(edited) }
                }
                Button(isEditing ? "PREVIEW" : "EDIT") { isEditing.toggle() }
                Button("COPY") { MarkdownText.copy(text) }
                    .help("Copies it formatted: bold stays bold in Telegram, Mail and Slack; apps without formatting, like a LinkedIn post, get plain text")
                ShareLink("SHARE", item: MarkdownText.plain(text))
                Button("DELETE") {
                    confirmation = PixelConfirmation(title: "DELETE THIS NOTE?", action: "DELETE") {
                        store.deleteReleaseNote(note.id!)
                    }
                }
            }
            .buttonStyle(PixelButtonStyle())
            Group {
                if isEditing {
                    TextEditor(text: $text)
                        .font(Fonts.mono(12))
                        .scrollContentBackground(.hidden)
                } else {
                    ScrollView {
                        Text(MarkdownText.attributed(text)).font(Fonts.ui(14)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(4)
                    }
                }
            }
            .foregroundStyle(Tokens.text)
            .padding(4)
            .background(Tokens.terminalBg)
            .sunken()
        }
        .onAppear { text = note.text }
        .onChange(of: text != note.text) { _, dirty in isDirty = dirty }
    }
}

/// The user's own posts: NEW copies their language, length, tone and formatting.
private struct StyleView: View {
    @Environment(AppStore.self) private var store
    @State private var samples = ""
    @State private var saved = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Paste 5–10 of your posts, separated by a line with ---. Kept in ~/.meepo/release-style.md.")
                    .font(.caption).foregroundStyle(Tokens.textDim)
                Spacer()
                Button("SAVE") {
                    try? FileManager.default.createDirectory(at: store.releaseStyleURL.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    if (try? samples.write(to: store.releaseStyleURL, atomically: true, encoding: .utf8)) != nil { saved = samples }
                }
                .buttonStyle(PixelButtonStyle())
                .disabled(samples == saved)
            }
            TextEditor(text: $samples)
                .font(Fonts.mono(12))
                .foregroundStyle(Tokens.text)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Tokens.terminalBg)
                .sunken()
        }
        .onAppear {
            saved = (try? String(contentsOf: store.releaseStyleURL, encoding: .utf8)) ?? ""
            samples = saved
        }
    }
}
