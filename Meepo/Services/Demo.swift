import Foundation

/// Demo mode (`open -n -a Meepo --args --demo`): made-up projects for screenshots, GIFs and videos — nobody's
/// real code on screen. In-memory database, its own settings, no claude started; terminals show a fixed page.
enum Demo {
    static var isOn: Bool {
        CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment["MEEPO_DEMO"] == "1"
    }

    struct SessionSpec {
        let project: String
        let name: String
        /// "working", "permission", "question", "ready".
        let state: String
        let request: String
        let files: [String]
        let terminal: String
        let model: String
        let effort: String
        let context: Double
        let tokens: Int
    }

    /// (project, files with contents, one uncommitted change)
    static let projects: [(name: String, files: [String: String], change: (file: String, text: String))] = [
        ("storefront", ["README.md": "# Storefront\n", "src/checkout/payment.ts": "export const pay = () => {}\n",
                        "src/payments/kaspi.ts": "export const kaspi = {}\n", "src/admin/report.ts": "export const report = []\n"],
         ("src/payments/refund.ts", "export async function refund(orderId: string) {\n  // new\n}\n")),
        ("fleet-api", ["README.md": "# Fleet API\n", "monitoring/poller.py": "def poll():\n    pass\n",
                       "tests/monitoring/test_poller.py": "def test_poll():\n    assert True\n"],
         ("monitoring/poller.py", "def poll(retries=3):\n    pass\n")),
        ("mobile", ["README.md": "# Mobile\n", "app/onboarding/Welcome.tsx": "export default () => null\n"],
         ("app/onboarding/Welcome.tsx", "export default () => 'Welcome'\n")),
    ]

    private static let esc = "\u{1B}["
    private static func dim(_ s: String) -> String { "\(esc)90m\(s)\(esc)0m" }
    private static func blue(_ s: String) -> String { "\(esc)34m\(s)\(esc)0m" }
    private static func green(_ s: String) -> String { "\(esc)32m\(s)\(esc)0m" }
    private static func orange(_ s: String) -> String { "\(esc)38;5;166m\(s)\(esc)0m" }
    private static func bold(_ s: String) -> String { "\(esc)1m\(s)\(esc)0m" }

    private static func header(_ folder: String) -> String {
        [" \(orange("✻")) \(bold("Claude Code")) v2.1.282 · Opus 5.5 (1M context) · xhigh",
         "   \(dim("~/Projects/\(folder)"))", ""].joined(separator: "\r\n")
    }

    static let sessions: [SessionSpec] = [
        SessionSpec(project: "storefront", name: "kaspi refunds", state: "working",
                    request: "add refunds for Kaspi payments to the checkout",
                    files: ["src/payments/refund.ts", "src/admin/report.ts"],
                    terminal: [header("storefront"),
                               "\(bold(">")) add refunds for Kaspi payments to the checkout", "",
                               "\(blue("⏺")) I'll add a refund flow: an endpoint, a Refund button on paid orders, and a column in the admin report.", "",
                               "\(blue("⏺")) \(bold("Read"))(src/payments/kaspi.ts)", "  \(dim("⎿  Read 142 lines"))", "",
                               "\(blue("⏺")) \(bold("Write"))(src/payments/refund.ts)", "  \(dim("⎿  Wrote 84 lines"))", "",
                               "\(blue("⏺")) \(bold("Bash"))(npm test -- payments)", "  \(dim("⎿  ")) \(green("38 passed")) \(dim("· 2.1s"))", "",
                               "\(orange("✻")) Adding the refunds column to the report… \(dim("(esc)"))"].joined(separator: "\r\n"),
                    model: "Opus 5.5", effort: "xhigh", context: 23, tokens: 412_000),
        SessionSpec(project: "fleet-api", name: "poller retries", state: "permission",
                    request: "retry the monitoring poller when the provider times out",
                    files: ["monitoring/poller.py"],
                    terminal: [header("fleet-api"),
                               "\(bold(">")) retry the monitoring poller when the provider times out", "",
                               "\(blue("⏺")) \(bold("Update"))(monitoring/poller.py)", "  \(dim("⎿  Added 18 lines, removed 4 lines"))", "",
                               "\(blue("⏺")) Now I'll run the monitoring tests.", "",
                               " \(bold("Bash command"))", "   pytest tests/monitoring -q", "",
                               " Do you want to proceed?",
                               " \(blue("❯ 1. Yes"))", "   2. Yes, and don't ask again for pytest commands", "   3. No, and tell Claude what to do differently"].joined(separator: "\r\n"),
                    model: "Sonnet 5", effort: "high", context: 41, tokens: 188_000),
        SessionSpec(project: "mobile", name: "welcome screen", state: "ready",
                    request: "rewrite the welcome screen copy, friendlier and shorter",
                    files: ["app/onboarding/Welcome.tsx"],
                    terminal: [header("mobile"),
                               "\(bold(">")) rewrite the welcome screen copy, friendlier and shorter", "",
                               "\(blue("⏺")) \(bold("Update"))(app/onboarding/Welcome.tsx)", "  \(dim("⎿  Changed 6 lines"))", "",
                               "\(blue("⏺")) Done. The welcome screen now says \"Your rides, one tap away\" with a single Get started button. QA passed on iOS and Android previews.", "",
                               "\(bold(">")) \(dim("▍"))"].joined(separator: "\r\n"),
                    model: "Opus 5.5", effort: "high", context: 12, tokens: 96_000),
        SessionSpec(project: "storefront", name: "login bug", state: "question",
                    request: "users get logged out after 5 minutes — find out why",
                    files: [],
                    terminal: [header("storefront"),
                               "\(bold(">")) users get logged out after 5 minutes — find out why", "",
                               "\(blue("⏺")) The session cookie is issued with maxAge 300 in src/auth/session.ts, and the refresh call only runs on page load, so an open tab expires after 5 minutes.", "",
                               "\(blue("⏺")) Should sessions last 30 days with a sliding refresh, or 24 hours? The second is safer for shared computers."].joined(separator: "\r\n"),
                    model: "Opus 5.5", effort: "xhigh", context: 8, tokens: 54_000),
    ]

    static let summary = #"{"headline":"Shoppers can get their Kaspi payment back","changes":[{"kind":"new","what":"A Refund button on paid orders","where":"Orders → Order details"},{"kind":"changed","what":"Refunds show in the daily report","where":"Admin → Finance → Daily report"}],"check":["Refunds over 50 000 ₸ need a manager's approval — is that the rule you want?"],"how_to_try":"Open a paid test order and press Refund; it appears in today's report."}"#

    static func statusLine(for spec: SessionSpec) -> Data {
        Data(#"""
        {"session_id":"demo","session_name":"\#(spec.name)","model":{"id":"demo","display_name":"\#(spec.model)"},"effort":{"level":"\#(spec.effort)"},
         "context_window":{"context_window_size":1000000,"used_percentage":\#(spec.context)},
         "rate_limits":{"five_hour":{"used_percentage":38,"resets_at":\#(Int(Date.now.addingTimeInterval(7200).timeIntervalSince1970))},
                        "seven_day":{"used_percentage":21,"resets_at":\#(Int(Date.now.addingTimeInterval(4 * 86_400).timeIntervalSince1970))}}}
        """#.utf8)
    }
}
