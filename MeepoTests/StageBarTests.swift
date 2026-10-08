import XCTest
@testable import Meepo

final class StageBarTests: XCTestCase {
    private let bar = ["code", "simplify", "ship", "sync"]

    /// One lit button, in the order a change goes out: tidy, ship, then save what was learned.
    func testNextStepFollowsTheWorkOut() {
        XCTAssertEqual(Stage.nextStep(after: "code", isReady: true, hasUncommitted: true, bar: bar), "simplify")
        XCTAssertEqual(Stage.nextStep(after: "simplify", isReady: true, hasUncommitted: true, bar: bar), "ship")
        XCTAssertEqual(Stage.nextStep(after: "ship", isReady: true, hasUncommitted: false, bar: bar), "sync")
        XCTAssertNil(Stage.nextStep(after: "sync", isReady: true, hasUncommitted: false, bar: bar), "all done: nothing lit")
        XCTAssertNil(Stage.nextStep(after: "code", isReady: false, hasUncommitted: true, bar: bar), "Claude is working: wait")
        XCTAssertNil(Stage.nextStep(after: nil, isReady: true, hasUncommitted: false, bar: bar), "nothing to do")
        XCTAssertEqual(Stage.nextStep(after: "code", isReady: true, hasUncommitted: true, bar: ["code", "ship"]), "ship",
                       "SIMP hidden: straight to SHIP, never a stage that isn't on the bar")
    }

    /// Size decides the path: a one-sentence change goes as typed; a feature starts with the spec interview.
    func testFirstPromptBySize() {
        XCTAssertEqual(Stage.firstPrompt("fix the typo", size: .small, spec: "meepo:spec"), "fix the typo")
        XCTAssertEqual(Stage.firstPrompt("add login", size: .feature, spec: "meepo:spec"), "/meepo:spec add login")
        XCTAssertTrue(Stage.firstPrompt("new billing", size: .big, spec: "meepo:spec").hasPrefix("/meepo:spec new billing\n\nIt's big"))
        XCTAssertEqual(Stage.firstPrompt("add login", size: .feature, spec: nil), "add login", "no spec command here: as typed")
        XCTAssertEqual(Stage.firstPrompt("", size: .feature, spec: "meepo:spec"), "", "no prompt: nothing to interview about")
    }

    /// Meepo's method: SPEC → PLAN, and REVIEW between tidying and shipping — never back to SIMP after it.
    func testNextStepThroughTheMethod() {
        let method = ["spec", "plan", "code", "simplify", "review", "ship", "sync"]
        XCTAssertEqual(Stage.nextStep(after: "spec", isReady: true, hasUncommitted: true, bar: method), "plan",
                       "the spec file isn't code to tidy")
        XCTAssertEqual(Stage.nextStep(after: "code", isReady: true, hasUncommitted: true, bar: method), "simplify")
        XCTAssertEqual(Stage.nextStep(after: "simplify", isReady: true, hasUncommitted: true, bar: method), "review")
        XCTAssertEqual(Stage.nextStep(after: "review", isReady: true, hasUncommitted: true, bar: method), "ship")
        XCTAssertEqual(Stage.nextStep(after: "ship", isReady: true, hasUncommitted: true, bar: method), "simplify",
                       "changed again after shipping: the round starts over")
    }

    /// Kept: what's run (typed or pressed, a stand-in counting for its stage) and CODE; not the rest.
    func testUsedKeepsWhatsRunAndCode() {
        let usage = ["sync": 56, "simplify": 49, "ship": 1, "commit-push-pr": 2, "plan": 2, "verify": 0]
        XCTAssertEqual(Stage.used(Stage.defaults, usage: usage).map(\.name), ["code", "simplify", "ship", "sync"])
    }
}
