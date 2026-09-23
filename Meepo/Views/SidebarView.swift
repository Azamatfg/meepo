import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var isPickingFolder = false
    @State private var addError: String?

    var body: some View {
        // Custom list instead of `List`: the system sidebar greys out selection whenever the
        // terminal has focus and highlights section headers on hover, so two things looked selected.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if store.projects.isEmpty {
                    Text("Нет проектов")
                        .foregroundStyle(Tokens.text.opacity(0.6))
                }
                ForEach(store.projects) { project in
                    ProjectHeader(project: project, isActive: store.selectedSession?.projectId == project.id) {
                        store.presentNewSession(projectId: project.id)
                    }
                    .padding(.top, 8)
                    ForEach(store.sessions.filter { $0.projectId == project.id }) { session in
                        SessionCard(session: session, isSelected: session.id == store.selectedSessionId)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        // Plain Tab / Shift+Tab switch sessions while the list (not the terminal) has focus.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.tab]) { press in
            store.selectSession(offset: press.modifiers.contains(.shift) ? -1 : 1)
            return .handled
        }
        .toolbar {
            Button("Добавить проект", systemImage: "plus") { isPickingFolder = true }
        }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            do {
                try store.addProject(at: result.get())
            } catch {
                addError = error.localizedDescription
            }
        }
        .alert("Не удалось добавить проект", isPresented: Binding(
            get: { addError != nil },
            set: { if !$0 { addError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addError ?? "")
        }
    }
}

private struct SessionCard: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let isSelected: Bool

    var body: some View {
        SessionLabel(session: session, projectName: nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Tokens.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Tokens.gold : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { store.selectedSessionId = session.id }
            .contextMenu {
                Button("Перезапустить") { store.restartSession(session.id!) }
                Button("Закрыть сессию", role: .destructive) { store.closeSession(session.id!) }
            }
    }
}

/// One session line: status dot, optional project name, branch and model.
struct SessionLabel: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let projectName: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            if let projectName {
                Text(projectName).foregroundStyle(Tokens.gold)
            }
            Text(session.branch ?? "без ветки")
            Text(session.model ?? "default")
                .font(.caption)
                .foregroundStyle(Tokens.text.opacity(0.6))
        }
        .help(statusText)
    }

    private var statusColor: Color {
        guard let id = session.id else { return .gray }
        if store.exitedSessionIds.contains(id) { return Tokens.fire }
        return store.runningSessionIds.contains(id) ? Tokens.moss : .gray
    }

    private var statusText: String {
        guard let id = session.id else { return "" }
        if store.exitedSessionIds.contains(id) { return "Завершена" }
        return store.runningSessionIds.contains(id) ? "Запущена" : "Не запущена — откройте, чтобы продолжить"
    }
}

private struct ProjectHeader: View {
    let project: Project
    let isActive: Bool
    let onNewSession: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.headline)
                    .foregroundStyle(isActive ? Tokens.gold : Tokens.text.opacity(0.7))
                Text(project.remote ?? "без remote")
                    .font(.caption)
                    .foregroundStyle(Tokens.text.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Новая сессия", systemImage: "plus.circle", action: onNewSession)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .help(project.path)
    }
}
