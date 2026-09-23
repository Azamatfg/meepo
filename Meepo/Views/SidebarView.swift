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
        .safeAreaInset(edge: .bottom) {
            if !store.isBridgeInstalled || store.bridgeError != nil || !store.notificationsAllowed {
                BridgeBanner()
            }
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

    private var isRunning: Bool {
        guard let id = session.id else { return false }
        return store.runningSessionIds.contains(id) && !store.exitedSessionIds.contains(id)
    }

    private var statusColor: Color {
        guard isRunning else { return Tokens.text.opacity(0.3) }
        return switch session.status {
        case .thinking: Tokens.glow
        case .waitingPermission: Tokens.fire
        case .waitingInput, .needsSync: Tokens.gold
        case .error: Tokens.danger
        case .idle: Tokens.moss
        }
    }

    private var statusText: String {
        guard let id = session.id else { return "" }
        if store.exitedSessionIds.contains(id) { return "Завершена" }
        guard isRunning else { return "Не запущена" }
        return switch session.status {
        case .thinking: "Работает"
        case .waitingPermission: "Ждёт разрешения"
        case .waitingInput: "Ждёт тебя"
        case .needsSync: "Пора sync"
        case .error: "Ошибка"
        case .idle: "Запущена"
        }
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

/// Shown until the hook bridge is installed, or when it/the event server has a problem.
private struct BridgeBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = store.bridgeError {
                Text(error)
                    .foregroundStyle(Tokens.danger)
            }
            if !store.notificationsAllowed {
                Text("Уведомления Meepo выключены в настройках macOS.")
                    .foregroundStyle(Tokens.text.opacity(0.7))
                Button("Открыть настройки уведомлений") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
            if !store.isBridgeInstalled {
                Text("Мост хуков не установлен: нет статусов и уведомлений.")
                    .foregroundStyle(Tokens.text.opacity(0.7))
                Button("Установить мост") { store.installBridge() }
                    .help("Добавит meepo-bridge.sh в ~/.claude/settings.json рядом с вашими хуками, а ваши Notification-хуки будут молчать в сессиях Meepo. Бэкапы — в ~/.meepo/backups")
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }
}
