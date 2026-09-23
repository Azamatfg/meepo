import SwiftUI

/// Right panel: hook events of the selected session, newest first; refusals and failures highlighted.
struct EventFeedView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.selectedEvents.isEmpty {
                Text(store.isBridgeInstalled ? "Событий пока нет" : "Установите мост, чтобы видеть события")
                    .foregroundStyle(Tokens.text.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.selectedEvents) { event in
                    EventRow(event: event)
                }
                .listStyle(.plain)
            }
        }
        .background(Tokens.background)
    }
}

private struct EventRow: View {
    let event: HookEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(Self.title(for: event.name))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(event.isFailure ? Tokens.danger : Tokens.text)
                Spacer()
                Text(event.createdAt, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Tokens.text.opacity(0.5))
            }
            if let summary = event.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Tokens.text.opacity(0.7))
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private static func title(for name: String) -> String {
        switch name {
        case "SessionStart": "Сессия запущена"
        case "SessionEnd": "Сессия завершена"
        case "UserPromptSubmit": "Промпт"
        case "PreToolUse": "Инструмент"
        case "PostToolUse": "Инструмент выполнен"
        case "PostToolUseFailure": "Инструмент упал"
        case "PermissionRequest": "Запрос разрешения"
        case "PermissionDenied": "Отказано"
        case "Notification": "Уведомление"
        case "Stop": "Ответ готов"
        case "StopFailure": "Сбой ответа"
        case "PreCompact": "Сжатие контекста"
        default: name
        }
    }
}
