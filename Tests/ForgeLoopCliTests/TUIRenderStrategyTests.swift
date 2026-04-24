import XCTest
import ForgeLoopTUI

/// STEP-023A TUI 渲染策略测试
///
/// 验证 RenderStrategy 切换、inlineAnchor 路径 ANSI 序列正确性、
/// 锁外 I/O（通过 writer 注入）、legacy 回滚可用性。
final class TUIRenderStrategyTests: XCTestCase {

    // MARK: - Spy

    private final class OutputSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _outputs: [String] = []

        var outputs: [String] {
            lock.withLock { Array(_outputs) }
        }

        var last: String? {
            lock.withLock { _outputs.last }
        }

        lazy var writer: FrameWriter = { [weak self] text in
            self?.lock.withLock { self?._outputs.append(text) }
        }
    }

    // MARK: - 1) 策略切换

    func testDefaultStrategyIsInline() {
        let tui = TUI()
        XCTAssertEqual(tui.strategy, .inlineAnchor)
    }

    func testExplicitLegacyStrategy() {
        let tui = TUI(strategy: .legacyAbsolute)
        XCTAssertEqual(tui.strategy, .legacyAbsolute)
    }

    func testExplicitInlineStrategy() {
        let tui = TUI(strategy: .inlineAnchor)
        XCTAssertEqual(tui.strategy, .inlineAnchor)
    }

    // MARK: - 2) Inline 首帧

    func testInlineFirstFrameHasNoClearScreen() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["hello", "world"])

        XCTAssertNotNil(spy.last)
        XCTAssertFalse(spy.last!.contains("\u{1B}[2J"), "First frame should not clear screen")
    }

    func testInlineFirstFrameOutputsDirectly() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["hello", "world"])

        XCTAssertEqual(spy.last, "hello\r\nworld\r\n")
    }

    func testInlineFirstFrameNormalizesEmbeddedNewlines() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["hello\nworld"])

        XCTAssertEqual(spy.last, "hello\r\nworld\r\n")
    }

    func testInlineEmptyFirstFrameOutputsNothing() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: [])

        XCTAssertEqual(spy.last, "")
    }

    // MARK: - 3) Inline 增量路径（无绝对定位）

    func testInlineIncrementalHasNoAbsolutePositioning() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["line1", "line2"])
        tui.requestRender(lines: ["line1", "line2b"])

        let allOutput = spy.outputs.joined()
        let absolutePositionPattern = "\u{1B}\\[\\d+;1H"
        let regex = try! NSRegularExpression(pattern: absolutePositionPattern, options: [])
        let range = NSRange(allOutput.startIndex..., in: allOutput)
        let matches = regex.matches(in: allOutput, options: [], range: range)
        XCTAssertEqual(matches.count, 0, "Incremental path must not use absolute positioning")
    }

    func testInlineIncrementalSequenceTwoLines() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["a", "b"])
        XCTAssertEqual(spy.last, "a\r\nb\r\n")

        tui.requestRender(lines: ["a", "c"])

        // Expected incremental sequence:
        // 1) \r + ESC[2A  (go back to top: 2 lines up from after the frame)
        // 2) ESC[2K\r\n ESC[2K\r\n  (clear 2 lines)
        // 3) ESC[2A  (back to top again)
        // 4) "a\r\nc\r\n"
        let expected = "\r\u{1B}[2A\u{1B}[2K\r\n\u{1B}[2K\r\n\u{1B}[2Aa\r\nc\r\n"
        XCTAssertEqual(spy.last, expected)
    }

    func testInlineIncrementalSequenceOneLine() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["only"])
        XCTAssertEqual(spy.last, "only\r\n")

        tui.requestRender(lines: ["changed"])

        // 1 line: \r + ESC[1A, clear once, ESC[1A back, new frame
        let expected = "\r\u{1B}[1A\u{1B}[2K\r\n\u{1B}[1Achanged\r\n"
        XCTAssertEqual(spy.last, expected)
    }

    // MARK: - 4) Inline shrink（短帧覆盖长帧）

    func testInlineShrinkCleansOldLines() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["long", "frame", "here"])
        tui.requestRender(lines: ["short"])

        let output = spy.outputs.last!
        // Should clear 3 old lines then draw 1 new line
        let clearCount = output.components(separatedBy: "\u{1B}[2K").count - 1
        XCTAssertEqual(clearCount, 3, "Should clear all 3 old lines")
    }

    // MARK: - 5) Inline 相同帧（无输出）

    func testInlineSameFrameProducesNoOutput() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["a", "b"])
        XCTAssertEqual(spy.outputs.count, 1)

        tui.requestRender(lines: ["a", "b"])
        // Same frame should not emit redundant redraw output.
        XCTAssertEqual(spy.outputs.count, 1)
    }

    // MARK: - 6) Legacy 路径

    func testLegacyFrameHasClearScreen() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .legacyAbsolute, writer: spy.writer)

        tui.requestRender(lines: ["hello"])

        XCTAssertTrue(spy.last!.contains("\u{1B}[2J"), "Legacy must clear screen")
    }

    func testLegacyFrameHasHomePosition() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .legacyAbsolute, writer: spy.writer)

        tui.requestRender(lines: ["hello"])

        XCTAssertTrue(spy.last!.contains("\u{1B}[H"), "Legacy must home cursor")
    }

    func testLegacyOutputsFullFrame() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .legacyAbsolute, writer: spy.writer)

        tui.requestRender(lines: ["a", "b"])

        XCTAssertEqual(spy.last, "\u{1B}[2J\u{1B}[Ha\r\nb\r\n")
    }

    func testLegacyRespectsCursorOffset() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .legacyAbsolute, writer: spy.writer)

        tui.requestRender(lines: ["prompt"], cursorOffset: 2)

        XCTAssertEqual(spy.last, "\u{1B}[2J\u{1B}[Hprompt\u{1B}[2D")
    }

    func testLegacyEmptyFrame() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .legacyAbsolute, writer: spy.writer)

        tui.requestRender(lines: [])

        XCTAssertEqual(spy.last, "\u{1B}[2J\u{1B}[H")
    }

    // MARK: - 7) Writer 注入验证（I/O 不在锁内）

    func testWriterReceivesOutput() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["test"])

        XCTAssertEqual(spy.outputs.count, 1)
        XCTAssertEqual(spy.outputs[0], "test\r\n")
    }

    func testWriterCalledForIncrementalRenders() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["a"])
        tui.requestRender(lines: ["b"])
        tui.requestRender(lines: ["c"])

        XCTAssertEqual(spy.outputs.count, 3)
    }

    // MARK: - 8) 多帧递增

    func testInlineMultipleIncrementalRenders() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["frame1"])
        tui.requestRender(lines: ["frame2"])
        tui.requestRender(lines: ["frame3"])

        // First frame: direct output
        XCTAssertEqual(spy.outputs[0], "frame1\r\n")

        // Incremental: go back, clear 1, back, draw
        let expectedIncremental = "\r\u{1B}[1A\u{1B}[2K\r\n\u{1B}[1Aframe2\r\n"
        XCTAssertEqual(spy.outputs[1], expectedIncremental)

        // Third render also incremental
        XCTAssertEqual(spy.outputs[2], expectedIncremental.replacingOccurrences(of: "frame2", with: "frame3"))
    }

    // MARK: - 9) Physical row shrink (long lines that wrap)

    func testInlineShrinkWithWrappedLinesCleansPhysicalRows() {
        let spy = OutputSpy()
        // Terminal width = 10, so "1234567890123" (13 visible chars) wraps to 2 physical rows
        let tui = TUI(strategy: .inlineAnchor, terminalWidth: 10, writer: spy.writer)

        tui.requestRender(lines: ["1234567890123"]) // 2 physical rows
        tui.requestRender(lines: ["short"])          // 1 physical row

        let output = spy.outputs.last!
        // Should clear 2 old physical rows (not 1 logical row)
        let clearCount = output.components(separatedBy: "\u{1B}[2K").count - 1
        XCTAssertEqual(clearCount, 2, "Should clear all 2 old physical rows")
    }

    func testInlineShrinkWithWrappedMultiLineCleansAllPhysicalRows() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, terminalWidth: 10, writer: spy.writer)

        // Line 1: 5 chars = 1 physical row
        // Line 2: 25 chars = 3 physical rows
        // Total: 4 physical rows
        tui.requestRender(lines: ["12345", "1234567890123456789012345"])
        tui.requestRender(lines: ["x"])

        let output = spy.outputs.last!
        let clearCount = output.components(separatedBy: "\u{1B}[2K").count - 1
        XCTAssertEqual(clearCount, 4, "Should clear all 4 old physical rows")
    }

    // MARK: - 10) Resize forces full redraw

    func testResizeInvalidatesAndForcesFullRedraw() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["frame1", "frame2"])

        // Simulate resize
        tui.updateTerminalSize(width: 100)

        tui.requestRender(lines: ["frame3", "frame4"])
        let afterResize = spy.outputs.last!

        // After resize, should do full region redraw: go back to top, clear old area, redraw
        XCTAssertTrue(afterResize.contains("\u{1B}[2A"), "Resize should rewind to old frame top")
        XCTAssertTrue(afterResize.contains("\u{1B}[2K"), "Resize should clear old frame area")
        XCTAssertTrue(afterResize.contains("frame3\r\nframe4"), "Should redraw new frame after clearing")
    }

    func testInvalidateForcesFullRedraw() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["a", "b"])
        tui.invalidate()
        tui.requestRender(lines: ["c", "d"])

        let output = spy.outputs.last!
        XCTAssertTrue(output.contains("\u{1B}[2A"), "Invalidate should trigger rewind")
        XCTAssertTrue(output.contains("\u{1B}[2K"), "Invalidate should trigger clear")
        XCTAssertTrue(output.contains("c\r\nd"), "Should redraw after clear")
    }

    // MARK: - 11) Cursor marker

    func testCursorOffsetPositionsCursor() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["input line"], cursorOffset: 3)

        let output = spy.outputs.last!
        // With cursorOffset, no trailing \n; cursor stays on last line
        XCTAssertEqual(output, "input line\u{1B}[3D", "Should position cursor 3 chars left without trailing newline")
    }

    func testCursorOffsetZeroProducesNoSequence() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["line"], cursorOffset: 0)

        let output = spy.outputs.last!
        // With cursorOffset=0, no \n appended, no ESC[0D emitted
        XCTAssertEqual(output, "line", "Should not append newline when cursorOffset is set")
        XCTAssertFalse(output.contains("\u{1B}[0D"))
    }

    func testCursorOffsetNilProducesNoSequence() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["line"], cursorOffset: nil)

        let output = spy.outputs.last!
        // With nil cursorOffset, \n is appended normally
        XCTAssertEqual(output, "line\r\n")
        XCTAssertFalse(output.contains("\u{1B}["))
    }

    func testCursorOffsetMultiLineContinuousRender() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        // Frame 1: 2 lines, cursor anchored on last line
        tui.requestRender(lines: ["line1", "line2"], cursorOffset: 0)
        XCTAssertEqual(spy.outputs[0], "line1\r\nline2")

        // Frame 2: prevRows=2, wasAnchored=true, rewindRows=1
        tui.requestRender(lines: ["new1", "new2"], cursorOffset: 0)
        let output = spy.outputs[1]

        // Should rewind 1 line (not 2) because cursor was anchored on last line
        XCTAssertTrue(output.contains("\u{1B}[1A"), "Anchored cursor should rewind prevRows-1 lines")
        // Should still clear all 2 physical rows
        let clearCount = output.components(separatedBy: "\u{1B}[2K").count - 1
        XCTAssertEqual(clearCount, 2, "Should clear all 2 old physical rows")
        // New frame should have no trailing \n
        XCTAssertTrue(output.hasSuffix("new1\r\nnew2"))
    }

    func testCursorOffsetSingleLineContinuousRender() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        // Frame 1: 1 line, cursor anchored
        tui.requestRender(lines: ["line1"], cursorOffset: 0)
        XCTAssertEqual(spy.outputs[0], "line1")

        // Frame 2: prevRows=1, wasAnchored=true, rewindRows=0
        tui.requestRender(lines: ["new1"], cursorOffset: 0)
        let output = spy.outputs[1]

        // Should not emit ESC[0A (rewindRows=0)
        XCTAssertFalse(output.contains("\u{1B}[0A"), "Single anchored line needs no rewind")
        // Should still clear 1 row
        let clearCount = output.components(separatedBy: "\u{1B}[2K").count - 1
        XCTAssertEqual(clearCount, 1)
        // New frame should have no trailing \n
        XCTAssertTrue(output.hasSuffix("new1"))
    }

    func testInlineOverflowFallsBackToFullRedraw() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, terminalWidth: 10, terminalHeight: 2, writer: spy.writer)

        tui.requestRender(lines: ["12345678901", "tail"], cursorOffset: 0)

        XCTAssertNotNil(spy.last)
        let output = spy.last!
        XCTAssertTrue(output.hasPrefix("\u{1B}[2J\u{1B}[H"), "Overflow frame should use full redraw path")
        XCTAssertFalse(output.contains("\u{1B}[1A"), "Overflow fallback must not use inline rewind into viewport")
        XCTAssertTrue(output.hasSuffix("tail"))
    }

    func testAppendFrameOutputsPlainFullFrame() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.appendFrame(lines: ["line1", "line2"])

        XCTAssertEqual(spy.last, "line1\r\nline2\r\n")
        XCTAssertFalse(spy.last!.contains("\u{1B}["))
    }

    func testResetRetainedFrameMakesNextInlineRenderFresh() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, writer: spy.writer)

        tui.requestRender(lines: ["old"])
        tui.appendFrame(lines: ["stream"])
        tui.resetRetainedFrame()
        tui.requestRender(lines: ["new"])

        XCTAssertEqual(spy.outputs.last, "new\r\n")
    }

    // MARK: - 12) Non-TTY fallback

    func testNonTTYOutputsPlainText() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, isTTY: false, writer: spy.writer)

        tui.requestRender(lines: ["hello", "world"])

        let output = spy.outputs.last!
        XCTAssertEqual(output, "hello\nworld\n")
        XCTAssertFalse(output.contains("\u{1B}"), "Non-TTY must not emit ANSI sequences")
    }

    func testNonTTYIgnoresLegacyStrategy() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .legacyAbsolute, isTTY: false, writer: spy.writer)

        tui.requestRender(lines: ["hello"])

        let output = spy.outputs.last!
        XCTAssertEqual(output, "hello\n")
        XCTAssertFalse(output.contains("\u{1B}[2J"), "Non-TTY must not clear screen even with legacy strategy")
    }

    func testNonTTYRespectsCursorOffset() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, isTTY: false, writer: spy.writer)

        tui.requestRender(lines: ["hello"], cursorOffset: 5)

        let output = spy.outputs.last!
        // Non-TTY with cursorOffset should not append trailing \n
        XCTAssertEqual(output, "hello")
        XCTAssertFalse(output.contains("\u{1B}"))
    }

    // MARK: - 13) Physical rows with ANSI sequences

    func testPhysicalRowsWithANSISequences() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, terminalWidth: 10, writer: spy.writer)

        // ANSI color codes don't contribute to visible width
        let line = "\u{1B}[31m1234567890\u{1B}[0m" // 10 visible chars, 1 physical row in width 10
        tui.requestRender(lines: [line])
        tui.requestRender(lines: ["short"])

        let output = spy.outputs.last!
        // 10 visible chars in width 10 terminal = 1 physical row
        let clearCount = output.components(separatedBy: "\u{1B}[2K").count - 1
        XCTAssertEqual(clearCount, 1, "ANSI stripped: 10 visible chars = 1 physical row")
    }

    func testPhysicalRowsWithANSISequencesWrap() {
        let spy = OutputSpy()
        let tui = TUI(strategy: .inlineAnchor, terminalWidth: 10, writer: spy.writer)

        // 15 visible chars with ANSI => 2 physical rows
        let line = "\u{1B}[31m123456789012345\u{1B}[0m"
        tui.requestRender(lines: [line])
        tui.requestRender(lines: ["x"])

        let output = spy.outputs.last!
        let clearCount = output.components(separatedBy: "\u{1B}[2K").count - 1
        XCTAssertEqual(clearCount, 2, "ANSI stripped: 15 visible chars = 2 physical rows in width 10")
    }

    // MARK: - 14) Terminal width parameter

    func testTUITerminalWidthDefault() {
        let tui = TUI()
        XCTAssertEqual(tui.terminalWidth, 80)
    }

    func testTUITerminalWidthCustom() {
        let tui = TUI(terminalWidth: 120)
        XCTAssertEqual(tui.terminalWidth, 120)
    }

    func testUpdateTerminalSizeChangesWidth() {
        let tui = TUI(terminalWidth: 80)
        tui.updateTerminalSize(width: 120)
        XCTAssertEqual(tui.terminalWidth, 120)
    }
}
