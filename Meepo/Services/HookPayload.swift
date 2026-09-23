import Foundation

/// A Claude Code hook event forwarded by meepo-bridge.sh. Parsed leniently: unknown fields are
/// ignored and missing ones stay nil, so new Claude Code versions don't break Meepo.
/// Field names verified against Claude Code 2.1.280 (hooks docs + a real run).
struct HookPayload: Equatable {
    var event: String
    var claudeSessionId: String
    var source: String?
    var notificationType: String?
    var message: String?
    var prompt: String?
    var toolName: String?
    var toolTarget: String?
    var lastAssistantMessage: String?
    /// Slash command name from UserPromptExpansion, e.g. "plan" for "/plan add login".
    var commandName: String?

    init(event: String, claudeSessionId: String, source: String? = nil, notificationType: String? = nil,
         message: String? = nil, prompt: String? = nil, toolName: String? = nil, toolTarget: String? = nil,
         lastAssistantMessage: String? = nil, commandName: String? = nil) {
        self.event = event
        self.claudeSessionId = claudeSessionId
        self.source = source
        self.notificationType = notificationType
        self.message = message
        self.prompt = prompt
        self.toolName = toolName
        self.toolTarget = toolTarget
        self.lastAssistantMessage = lastAssistantMessage
        self.commandName = commandName
    }

    init?(json: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let event = obj["hook_event_name"] as? String,
              let sessionId = obj["session_id"] as? String else { return nil }
        let input = obj["tool_input"] as? [String: Any]
        let question = (input?["questions"] as? [[String: Any]])?.first?["question"] as? String
        self.init(
            event: event,
            claudeSessionId: sessionId,
            source: obj["source"] as? String,
            notificationType: obj["notification_type"] as? String,
            message: (obj["message"] ?? obj["error"]) as? String,
            prompt: obj["prompt"] as? String,
            toolName: obj["tool_name"] as? String,
            // The most telling argument of common tools: Bash command, file path, URL, search pattern.
            toolTarget: question ?? ["command", "file_path", "url", "pattern"].lazy.compactMap { input?[$0] as? String }.first,
            lastAssistantMessage: obj["last_assistant_message"] as? String,
            commandName: obj["command_name"] as? String
        )
    }

    /// Claude asks the user a multiple-choice question: it arrives as a permission request for this tool.
    var isQuestion: Bool { toolName == "AskUserQuestion" }

    /// Status the event puts the session in; nil when the event says nothing about it.
    var status: SessionStatus? {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
             "SubagentStart", "SubagentStop", "PreCompact", "PostCompact":
            .thinking
        case "PermissionRequest":
            isQuestion ? .waitingInput : .waitingPermission
        case "Notification":
            switch notificationType {
            case "permission_prompt": .waitingPermission
            case "idle_prompt": .waitingInput
            default: nil
            }
        case "Stop": .waitingInput
        case "StopFailure": .error
        case "SessionStart", "SessionEnd": .idle
        default: nil
        }
    }

    /// Something was refused or failed: highlighted in the feed.
    var isFailure: Bool {
        ["PermissionDenied", "PostToolUseFailure", "StopFailure"].contains(event)
    }

    /// One line for the feed and notification body.
    var summary: String? {
        if isQuestion, let toolTarget { return toolTarget }
        if let toolName {
            return [toolName, toolTarget].compactMap { $0 }.joined(separator: ": ")
        }
        return lastAssistantMessage ?? message ?? prompt ?? source
    }
}

/// Why a session needs the user; each kind becomes a notification.
enum Attention: Equatable {
    case permission, question, done, error

    /// Notify only when the session *enters* a waiting state from real work, so the pair
    /// PermissionRequest + Notification(permission_prompt) or a later idle_prompt don't notify twice.
    static func from(_ old: SessionStatus, to new: SessionStatus) -> Attention? {
        guard old != new else { return nil }
        switch new {
        case .waitingPermission: return .permission
        case .waitingInput: return old == .thinking ? .done : nil // a question is refined by the caller
        case .error: return .error
        case .thinking, .idle, .needsSync: return nil
        }
    }
}
