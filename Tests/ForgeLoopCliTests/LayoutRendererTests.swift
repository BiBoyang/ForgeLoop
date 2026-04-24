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

    // MARK: - Full Transcript Output

    func testTranscriptOutputInFull() {
        var layout = Layout()
        layout.transcript = ["a", "b", "c"]
        let config = LayoutConfig(terminalHeight: 10)
        let frame = renderer.render(layout: layout, config: config)
        XCTAssertEqual(frame, ["a", "b", "c"])
    }

    func testLongTranscriptNotTruncated() {
        var layout = Layout()
        layout.transcript = (0..<100).map { "line\($0)" }
        let config = LayoutConfig(terminalHeight: 10)
        let frame = renderer.render(layout: layout, config: config)
        XCTAssertEqual(frame.count, 100)
        XCTAssertEqual(frame.first, "line0")
        XCTAssertEqual(frame.last, "line99")
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

    func testStatusAndInputAfterTranscript() {
        var layout = Layout()
        layout.transcript = ["t1", "t2"]
        layout.status = ["STATUS"]
        layout.input = ["> "]
        let config = LayoutConfig(terminalHeight: 10)
        let frame = renderer.render(layout: layout, config: config)
        XCTAssertEqual(frame, ["t1", "t2", "", "STATUS", "", "> "])
    }

    func testHeaderHiddenWhenShowHeaderFalse() {
        var layout = Layout()
        layout.header = ["H1", "H2"]
        layout.transcript = ["T"]
        let config = LayoutConfig(terminalHeight: 24, showHeader: false)
        let frame = renderer.render(layout: layout, config: config)
        XCTAssertEqual(frame, ["T"])
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

    func testEmptyQueueDoesNotAddDivider() {
        var layout = Layout()
        layout.transcript = ["t1"]
        layout.status = ["STATUS"]
        layout.input = ["> "]
        let config = LayoutConfig(terminalHeight: 10)
        let frame = renderer.render(layout: layout, config: config)
        XCTAssertEqual(frame, ["t1", "", "STATUS", "", "> "])
    }

    // MARK: - Pinned Range (no effect, full output)

    func testPinnedRangeDoesNotAffectOutput() {
        var layout = Layout()
        layout.transcript = ["old1", "old2", "stream1", "stream2"]
        layout.pinnedTranscriptRange = 2..<4
        let config = LayoutConfig(terminalHeight: 3)
        let frame = renderer.render(layout: layout, config: config)
        XCTAssertEqual(frame, ["old1", "old2", "stream1", "stream2"])
    }
}
