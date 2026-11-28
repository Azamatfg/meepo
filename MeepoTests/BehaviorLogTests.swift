import XCTest
@testable import Meepo

final class BehaviorLogTests: XCTestCase {
    func testOnlyChangedFieldsBecomeLines() {
        let old = ["home": "false", "preset": "focus", "session": "1 meepo"]
        let new = ["home": "true", "preset": "focus", "session": "2 taxi"]
        XCTAssertEqual(BehaviorLog.changes(from: old, to: new).map { "\($0.0)=\($0.1)" }, ["home=true", "session=2 taxi"])
        XCTAssertTrue(BehaviorLog.changes(from: new, to: new).isEmpty)
    }

    func testLineIsOneJSONObjectWithTheDate() throws {
        let line = BehaviorLog.line("hook", ["prompt": "fix it\nnow \"please\""], at: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(line.contains("\n")) // a prompt's newlines must not split the line
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        XCTAssertEqual(object["kind"], "hook")
        XCTAssertEqual(object["prompt"], "fix it\nnow \"please\"")
        XCTAssertTrue(object["t"]?.hasPrefix("1970-01-01") == true || object["t"]?.hasPrefix("1969-12-31") == true)
    }
}
