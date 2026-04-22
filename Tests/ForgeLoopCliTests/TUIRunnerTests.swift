import XCTest
@testable import ForgeLoopCli

final class TUIRunnerTests: XCTestCase {
    func testWithUTF8EraseFlagSetsBit() {
        let flags: tcflag_t = 0
        let updated = withUTF8EraseFlag(flags)
        XCTAssertTrue(hasUTF8EraseFlag(updated))
    }

    func testWithUTF8EraseFlagIsIdempotent() {
        let initial = withUTF8EraseFlag(0)
        let updated = withUTF8EraseFlag(initial)
        XCTAssertEqual(initial, updated)
        XCTAssertTrue(hasUTF8EraseFlag(updated))
    }
}
