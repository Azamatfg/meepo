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

    /// A commit after "Start": `pushed` = minutes ago it went out together with the unsent ones before it.
    struct CommitSpec {
        let message: String
        let file: String
        let text: String
        let minutesAgo: Double
        var pushed: Double?
    }

    /// (project, files with contents, commits after "Start", one change left uncommitted)
    static let projects: [(name: String, files: [String: String], history: [CommitSpec], change: (file: String, text: String)?)] = [
        ("storefront", ["README.md": "# Storefront\n", "src/checkout/payment.ts": "export const pay = () => {}\n",
                        "src/payments/kaspi.ts": "export const kaspi = {}\n", "src/admin/report.ts": "export const report = []\n"],
         [CommitSpec(message: "feat(checkout): pay with Kaspi at checkout", file: "src/checkout/payment.ts",
                     text: "export const pay = (method: 'card' | 'kaspi') => {}\n", minutesAgo: 200),
          CommitSpec(message: "chore: update the payments SDK", file: "package.json", text: "{ \"payments\": \"4.2.0\" }\n",
                     minutesAgo: 196, pushed: 185),
          CommitSpec(message: "fix(orders): totals include delivery", file: "src/orders/total.ts",
                     text: "export const total = (items: number, delivery: number) => items + delivery\n", minutesAgo: 124, pushed: 118)],
         ("src/payments/refund.ts", "export async function refund(orderId: string) {\n  // new\n}\n")),
        ("fleet-api", ["README.md": "# Fleet API\n", "monitoring/poller.py": "def poll():\n    pass\n",
                       "tests/monitoring/test_poller.py": "def test_poll():\n    assert True\n"],
         [CommitSpec(message: "feat(monitoring): alert when a payment provider is down", file: "monitoring/alerts.py",
                     text: "def alert(provider):\n    pass\n", minutesAgo: 306, pushed: 300)],
         ("monitoring/poller.py", "def poll(retries=3):\n    pass\n")),
        ("mobile", ["README.md": "# Mobile\n", "app/onboarding/Welcome.tsx": "export default () => null\n"],
         [CommitSpec(message: "feat(onboarding): friendlier welcome screen", file: "app/onboarding/Welcome.tsx",
                     text: "export default () => 'Your rides, one tap away'\n", minutesAgo: 8)],
         nil),
    ]

    /// Earlier requests of a session (index into `sessions`), for What changed and Today: asked `minutesAgo`,
    /// answered `minutes` later; a helper's report on the way shows as Claude Code's own line.
    static let earlier: [(session: Int, request: String, reply: String, minutesAgo: Double, minutes: Double, file: String?, helper: String?)] = [
        (0, "let shoppers pay with Kaspi at checkout",
         "Kaspi is now a payment option at checkout, and paid orders show the method in the admin. Tests pass.\n\nCommit and push?",
         215, 12, "src/checkout/payment.ts", "Payment tests"),
        (0, "yes, commit and push", "Pushed 2 commits to main. CI passed; Deploy waits for your click.", 190, 6, nil, nil),
        (0, "the order total misses delivery — fix it",
         "Fixed and pushed: order totals now include delivery, on the order page and in the receipt.", 135, 18, "src/orders/total.ts", nil),
        (1, "alert us when a payment provider is down", "Done and pushed: a Slack alert fires after 3 failed checks in a row.",
         330, 30, "monitoring/alerts.py", nil),
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

    /// Sessions outside meepo: a background agent waiting for an answer, and claude open in VS Code.
    /// `folder`: a demo project's path by name.
    static func agents(folder: (String) -> String?) -> [ClaudeAgents.Agent] {
        [ClaudeAgents.Agent(id: "a41c9e02", kind: "background", sessionId: "a41c9e02-7d3b-4f0e-9c21-5be8d0f3a611",
                            cwd: folder("storefront"), name: "nightly price sync", state: "blocked",
                            startedAt: .now - 2 * 3600),
         ClaudeAgents.Agent(id: "5e0b7c9d-2f14-4a88-b6d3-91c0e4a7f252", kind: "interactive",
                            sessionId: "5e0b7c9d-2f14-4a88-b6d3-91c0e4a7f252", cwd: folder("fleet-api"),
                            name: "rate limits", state: "busy", pid: 4242, startedAt: .now - 40 * 60, host: "VS Code")]
    }

    /// What `claude logs` shows for the background agent.
    static let agentOutput = """
    > sync tonight's prices from the supplier feed into the catalog

    ⏺ Read(src/catalog/prices.ts)
      ⎿  Read 96 lines

    ⏺ Bash(npm run feed:download)
      ⎿  Downloaded 4,812 prices

    ⏺ 312 prices dropped by more than 30%. Should I apply them, or hold those for a person to check?
    """

    /// Explain for users on storefront's Kaspi push.
    static let summary = #"{"headline":"Shoppers can pay with Kaspi at checkout","changes":[{"kind":"new","what":"Kaspi is a payment option next to the card","where":"Checkout → Payment"},{"kind":"changed","what":"A paid order shows how it was paid","where":"Admin → Orders → Order details"},{"kind":"changed","what":"Kaspi payments get their own line in the daily report","where":"Admin → Finance → Daily report"}],"check":["Kaspi's test mode is still on — switch it off before the release?","What happens when a shopper closes Kaspi before paying?"],"how_to_try":"Put something in the cart, pick Kaspi at checkout and pay with the test account."}"#

    static func statusLine(for spec: SessionSpec) -> Data {
        Data(#"""
        {"session_id":"demo","session_name":"\#(spec.name)","model":{"id":"demo","display_name":"\#(spec.model)"},"effort":{"level":"\#(spec.effort)"},
         "context_window":{"context_window_size":1000000,"used_percentage":\#(spec.context)},
         "rate_limits":{"five_hour":{"used_percentage":38,"resets_at":\#(Int(Date.now.addingTimeInterval(7200).timeIntervalSince1970))},
                        "seven_day":{"used_percentage":21,"resets_at":\#(Int(Date.now.addingTimeInterval(4 * 86_400).timeIntervalSince1970))}}}
        """#.utf8)
    }
}
