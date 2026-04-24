import XCTest
@testable import ForgeLoopTUI

final class LogicalLinesTests: XCTestCase {
    func testSplitLogicalLinesNormalizesCRLFAndCR() {
        XCTAssertEqual(
            splitLogicalLines("a\r\nb\rc\n"),
            ["a", "b", "c", ""]
        )
    }

    func testPrefixedLogicalLinesSplitsMultilineInput() {
        XCTAssertEqual(
            prefixedLogicalLines(prefix: "❯ ", text: "first\nsecond\nthird"),
            ["❯ first", "second", "third"]
        )
    }

    func testPrefixedLogicalLinesKeepsEmptyInputPrompt() {
        XCTAssertEqual(prefixedLogicalLines(prefix: "❯ ", text: ""), ["❯ "])
    }
}
