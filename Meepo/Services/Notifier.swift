import Foundation
import os
import UserNotifications

private let log = Logger(subsystem: "com.azamatfg.meepo", category: "notifications")

/// macOS notifications that say which session needs what; clicking one opens that session.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onOpen: ((Int64) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asks once; macOS answers "not allowed" without a prompt when the user turned Meepo off in System Settings.
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            log.notice("notifications not allowed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func post(_ attention: Attention, session: Session, project: Project?, summary: String?) {
        guard let id = session.id else { return }
        let content = UNMutableNotificationContent()
        content.title = [project?.name, session.branch].compactMap { $0 }.joined(separator: " · ")
        content.subtitle = switch attention {
        case .permission: "Needs permission"
        case .question: "Asks a question"
        case .done: "Done — waiting for you"
        case .error: "Error"
        }
        content.body = Self.plainText(summary ?? "")
        content.sound = .default
        content.threadIdentifier = "session-\(id)"
        content.userInfo = ["sessionId": Int(id)]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { log.error("post failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Plain notice (CI results); clicking it just opens Meepo.
    func postText(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Claude answers in Markdown; a notification shows raw text, so drop the markup and blank lines.
    nonisolated static func plainText(_ markdown: String, limit: Int = 180) -> String {
        var text = markdown
            .replacingOccurrences(of: #"```[^\n]*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*(#+|[-*>]) +"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if text.count > limit { text = text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…" }
        return text
    }

    /// Current permission without prompting; used when the user comes back from System Settings.
    func isAuthorized() async -> Bool {
        await center.notificationSettings().authorizationStatus == .authorized
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["sessionId"] as? Int else { return }
        await MainActor.run { onOpen?(Int64(id)) }
    }

    /// Show banners even while Meepo is frontmost (the caller already skips the session being viewed).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
