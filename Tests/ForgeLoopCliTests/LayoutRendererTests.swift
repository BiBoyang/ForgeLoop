import XCTest
@testable import ForgeLoopTUI

final class LayoutRendererTests: XCTestCase {

    private var renderer: LayoutRenderer!

    override func setUp() {
        renderer = LayoutRenderer()
    }

    // MARK: - Empty / Minimal

    func testEmptyLayoutReturnsEmpty() {
        let layout = Layout()
        let config = LayoutConfig(terminalHeight: 24)
        let frame = renderer.render(layout: layout, config: config)
        XCTAssertEqual(frame, [])
    }

    func testHeaderOnly() {
        var layout = Layout()
        layout.header = ["Header"]
        let config = LayoutConfig(terminalHeight: 24)
        let frame = renderer.render(layout: layout, config: config)
        XCTAssertEqual(frame, ["Header"])
    }

    // MARK: - Transcript Budget

    func testTranscriptFitsWithinBudget() {
        var layout = Layout()
        layout.transcript = ["a", "b", "c"]
        let config = LayoutConfig(terminalHeight: 10)
        let frame = renderer.render(layout: layout, config: config)
        XCTAssertEqual(frame, ["a", "b", "c"])
    }

    func testTranscriptTruncatedToBudget() {
        var layout = Layout()
        layout.transcript = (0..<100).map { "line\($0)" }
        let config = LayoutConfig(terminalHeight: 10)
        let frame = renderer.render(layout: layout, config: config)
        // Only last 10 lines fit
        XCTAssertEqual(frame.count, 10)
        XCTAssertEqual(frame.first, "line90")
        XCTAssertEqual(frame.last, "line99")
    }

    func testTranscriptBudgetReservesSpaceForStatus() {
        var layout = Layout()
        layout.transcript = (0..<100).map { "line\($0)" }
        layout.status = ["status"]
        let config = LayoutConfig(terminalHeight: 10)
        let frame = renderer.render(layout: layout, config: config)
        // status + divider = 2 rows overhead
        // transcript budget = 10 - 2 = 8
        XCTAssertEqual(frame.count, 10) // 8 transcript + 1 divider + 1 status
    }

    func testTranscriptBudgetReservesSpaceForStatusAndInput() {
        var layout = Layout()
        layout.transcript = (0..<100).map { "line\($0)" }
        layout.status = ["status"]
        layout.input = ["> input"]
        let config = LayoutConfig(terminalHeight: 10)
        let frame = renderer.render(layout: layout, config: config)
        // status + input + 2 dividers = 4 rows overhead
        // transcript budget = 10 - 4 = 6
        XCTAssertEqual(frame.count, 10) // 6 transcript + 1 divider + 1 status + 1 divider + 1 input
    }

    // MARK: - Ordering

    func testRenderOrderHeaderTranscriptStatusInput() {
        var layout = Layout()
        layout.header = ["H"]
        layout.transcript = ["T1", "T2"]
        layout.status = ["S"]
        layout.input = ["I"]
        let config = LayoutConfig(terminalHeight: 24)
        let frame = renderer.render(layout: layout, config: config)

        XCTAssertEqual(frame, [
            "H",
            "T1", "T2",
            "",   // divider
            "S",
            "",   // divider
            "I",
        ])
    }

    func testStatusAndInputAtBottom() {
        var layout = Layout()
        layout.transcript = (0..<50).map { "t\($0)" }
        layout.status = ["STATUS"]
        layout.input = ["> "]
        let config = LayoutConfig(terminalHeight: 10)
        let frame = renderer.render(layout: layout, config: config)

        // Last elements should be status and input
        XCTAssertEqual(frame[frame.count - 1], "> ")
        XCTAssertEqual(frame[frame.count - 2], "")
        XCTAssertEqual(frame[frame.count - 3], "STATUS")
        XCTAssertEqual(frame[frame.count - 4], "")
    }

    // MARK: - Header Toggle

    func testHeaderHiddenWhenShowHeaderFalse() {
        var layout = Layout()
        layout.header = ["H1", "H2"]
        layout.transcript = ["T"]
        let config = LayoutConfig(terminalHeight: 24, showHeader: false)
        let frame = renderer.render(layout: layout, config: config)
        XCTAssertEqual(frame, ["T"])
    }

    // MARK: - Zero / Negative Budget

    func testZeroTerminalHeight() {
        var layout = Layout()
        layout.transcript = ["a", "b"]
        layout.status = ["s"]
        layout.input = ["> "]
        let config = LayoutConfig(terminalHeight: 0)
        let frame = renderer.render(layout: layout, config: config)
        // transcript budget = max(0, 0 - 0 - 4) = 0
        XCTAssertEqual(frame, ["", "s", "", "> "])
    }

    // MARK: - Queue

    func testQueueRenderedBetweenTranscriptAndStatus() {
        var layout = Layout()
        layout.transcript = ["t1"]
        layout.queue = ["q1", "q2"]
        layout.status = ["s1"]
        let config = LayoutConfig(terminalHeight: 10)
        let frame = renderer.render(layout: layout, config: config)
        XCTAssertEqual(frame, ["t1", "", "q1", "q2", "", "s1"])
    }

    func testQueueExpansionDoesNotPushInputOffScreen() {
        // 10-row terminal with header(1) + transcript + queue(3) + status(1) + input(1) + 3 dividers = 10
        var layout = Layout()
        layout.header = ["H"]
        layout.transcript = (0..<50).map { "t\($0)" }
        layout.queue = ["q1", "q2", "q3"]
        layout.status = ["STATUS"]
        layout.input = ["> "]
        let config = LayoutConfig(terminalHeight: 10)
        let frame = renderer.render(layout: layout, config: config)

        // budget: 10 - 1(header) - 4(queue+status+input+dividers) = 5 transcript lines
        XCTAssertEqual(frame.count, 10)
        // last element must be input (never pushed off)
        XCTAssertEqual(frame.last, "> ")
        // second-last is divider before input
        XCTAssertEqual(frame[frame.count - 2], "")
        // third-last is status
        XCTAssertEqual(frame[frame.count - 3], "STATUS")
    }

    func testEmptyQueueDoesNotConsumeRows() {
        var layout = Layout()
        layout.transcript = (0..<50).map { "t\($0)" }
        layout.status = ["STATUS"]
        layout.input = ["> "]
        let config = LayoutConfig(terminalHeight: 10)
        let frame = renderer.render(layout: layout, config: config)

        // No queue: overhead = status(1+1) + input(1+1) = 4
        // budget = 10 - 4 = 6 transcript lines
        // frame = 6 transcript + divider + status + divider + input = 10
        XCTAssertEqual(frame.count, 10)
    }

    // MARK: - Transcript Suffix (latest content visible)

    func testTranscriptShowsLatestLines() {
        var layout = Layout()
        layout.transcript = ["old1", "old2", "mid1", "mid2", "new1", "new2"]
        let config = LayoutConfig(terminalHeight: 4)
        let frame = renderer.render(layout: layout, config: config)
        XCTAssertEqual(frame, ["mid1", "mid2", "new1", "new2"])
    }

    // MARK: - Physical Row Budget

    func testTranscriptBudgetTruncatesWithWrappedLines() {
        var layout = Layout()
        // 20 visible chars in width 10 terminal = 2 physical rows each
        layout.transcript = (0..<10).map { String(repeating: "\($0)", count: 20) }
        let config = LayoutConfig(terminalHeight: 10, terminalWidth: 10)
        let frame = renderer.render(layout: layout, config: config)
        // 10 lines * 2 physical rows = 20 physical rows, budget = 10
        // Should show last 5 logical lines = 10 physical rows
        XCTAssertEqual(frame.count, 5)
    }

    func testTranscriptBudgetWithANSILongLines() {
        var layout = Layout()
        // Line with ANSI: visible chars = 15 (ANSI stripped), physical rows = 2 in width 10
        layout.transcript = ["\u{1B}[31m123456789012345\u{1B}[0m"]
        layout.status = ["status"]
        let config = LayoutConfig(terminalHeight: 5, terminalWidth: 10)
        let frame = renderer.render(layout: layout, config: config)
        // ANSI line = 2 physical rows, status + divider = 2 physical rows
        // budget = 5 - 2 = 3, line fits (2 <= 3)
        // frame = line + divider + status = 3 lines
        XCTAssertEqual(frame.count, 3)
        XCTAssertEqual(frame.first, "\u{1B}[31m123456789012345\u{1B}[0m")
        XCTAssertEqual(frame.last, "status")
    }

    func testPhysicalRowBudgetTruncatesEarlyWithLongLines() {
        var layout = Layout()
        layout.transcript = [
            "short",                               // 1 physical row
            "12345678901234567890",               // 2 physical rows (width=10)
            "123456789012345678901234567890",     // 3 physical rows
        ]
        layout.status = ["s"]
        let config = LayoutConfig(terminalHeight: 6, terminalWidth: 10)
        let frame = renderer.render(layout: layout, config: config)
        // status + divider = 2 physical rows
        // budget = 6 - 2 = 4
        // From end: line3 (3 rows, 3 <= 4, add), line2 (2 rows, 3+2=5 > 4, break)
        // frame = [line3] + divider + status = 3 lines
        XCTAssertEqual(frame.count, 3)
        XCTAssertEqual(frame.first, "123456789012345678901234567890")
        XCTAssertEqual(frame.last, "s")
    }

    func testPhysicalRowBudgetEmptyTranscriptWithOverhead() {
        var layout = Layout()
        layout.transcript = []
        layout.status = ["status"]
        layout.input = ["> "]
        let config = LayoutConfig(terminalHeight: 5, terminalWidth: 10)
        let frame = renderer.render(layout: layout, config: config)
        // Empty transcript, just dividers + status + input
        XCTAssertEqual(frame, ["", "status", "", "> "])
    }

    func testPhysicalRowBudgetCJKCharacters() {
        var layout = Layout()
        // "你好" has visible width 4 (each CJK char = 2)
        // In width 10 terminal = 1 physical row
        // In width 3 terminal = 2 physical rows
        layout.transcript = ["你好世界", "test"]
        let config = LayoutConfig(terminalHeight: 3, terminalWidth: 3)
        let frame = renderer.render(layout: layout, config: config)
        // "你好世界": 8 visible width, width=3 => 3 physical rows
        // "test": 4 visible width, width=3 => 2 physical rows
        // budget = 3
        // From end: "test" (2 rows, 2 <= 3, add), "你好世界" (3 rows, 2+3=5 > 3, break)
        // frame = ["test"]
        XCTAssertEqual(frame.count, 1)
        XCTAssertEqual(frame.first, "test")
    }

    func testPhysicalRowBudgetWideCharsAndASCIIMixed() {
        var layout = Layout()
        layout.transcript = [
            "abc",      // 3 width => 1 physical row (width=10)
            "中文测试",  // 8 width => 1 physical row
            "x",        // 1 width => 1 physical row
        ]
        let config = LayoutConfig(terminalHeight: 3, terminalWidth: 10)
        let frame = renderer.render(layout: layout, config: config)
        // budget = 3, all 3 lines fit (1+1+1 = 3 physical rows)
        XCTAssertEqual(frame.count, 3)
    }
}
