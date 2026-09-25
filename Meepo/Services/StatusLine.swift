import Foundation

/// What Claude Code hands a statusline command after each update (2.1.282): the model, effort, how full the
/// context is, and the plan's usage limits. Meepo's sessions send it through the bridge; parsed leniently.
struct StatusLine: Equatable {
    struct Limit: Equatable {
        var percent: Double
        var resetsAt: Date?
    }

    /// The name Claude Code shows for the session (`/rename`, `--name`).
    var sessionName: String?
    var modelId: String?
    var modelName: String?
    var effort: String?
    /// 0…100 of `contextWindow`, as Claude Code counts it.
    var contextPercent: Double?
    var contextWindow: Int?
    var fiveHour: Limit?
    var sevenDay: Limit?

    /// nil for anything that isn't a statusline update — hook events carry `hook_event_name`.
    init?(json: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              obj["hook_event_name"] == nil, obj["session_id"] is String,
              obj["model"] != nil || obj["context_window"] != nil else { return nil }
        sessionName = obj["session_name"] as? String
        let model = obj["model"] as? [String: Any]
        modelId = model?["id"] as? String
        modelName = model?["display_name"] as? String
        effort = (obj["effort"] as? [String: Any])?["level"] as? String
        let context = obj["context_window"] as? [String: Any]
        contextPercent = (context?["used_percentage"] as? NSNumber)?.doubleValue
        contextWindow = (context?["context_window_size"] as? NSNumber)?.intValue
        let limits = obj["rate_limits"] as? [String: Any]
        fiveHour = Self.limit(limits?["five_hour"])
        sevenDay = Self.limit(limits?["seven_day"])
    }

    private static func limit(_ value: Any?) -> Limit? {
        guard let dict = value as? [String: Any], let percent = (dict["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
        return Limit(percent: percent, resetsAt: (dict["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
    }
}
