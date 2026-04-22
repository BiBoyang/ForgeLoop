import XCTest
@testable import ForgeLoopTUI

@MainActor
final class TranscriptRendererTests: XCTestCase {
    // MARK: - 1) messageUpdate 覆盖：两次更新只保留后者文本

    func testStreamingUpdateReplacesPreviousContent() {
        let renderer = TranscriptRenderer()
        renderer.apply(.messageStart(message: .assistant(text: "", errorMessage: nil)))
        renderer.apply(.messageUpdate(message: .assistant(text: "first version", errorMessage: nil)))
        renderer.apply(.messageUpdate(message: .assistant(text: "second version", errorMessage: nil)))
        renderer.apply(.messageEnd(message: .assistant(text: "second version", errorMessage: nil)))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("second version"))
        XCTAssertFalse(lines.contains("first version"))
    }

    // MARK: - 2) 更新行数缩短：旧尾行不残留

    func testStreamingUpdateShortensLinesNoResidue() {
        let renderer = TranscriptRenderer()
        renderer.apply(.messageStart(message: .assistant(text: "", errorMessage: nil)))
        renderer.apply(.messageUpdate(message: .assistant(text: "line1\nline2\nline3", errorMessage: nil)))
        renderer.apply(.messageUpdate(message: .assistant(text: "only one", errorMessage: nil)))
        renderer.apply(.messageEnd(message: .assistant(text: "only one", errorMessage: nil)))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("only one"))
        XCTAssertFalse(lines.contains("line1"))
        XCTAssertFalse(lines.contains("line2"))
        XCTAssertFalse(lines.contains("line3"))
    }

    // MARK: - 3) messageEnd 后分隔空行只出现一次

    func testMessageEndAppendsSingleBlankSeparator() {
        let renderer = TranscriptRenderer()
        renderer.apply(.messageStart(message: .assistant(text: "", errorMessage: nil)))
        renderer.apply(.messageUpdate(message: .assistant(text: "hello", errorMessage: nil)))
        renderer.apply(.messageEnd(message: .assistant(text: "hello", errorMessage: nil)))

        let lines = renderer.lines.all
        let blankCount = lines.filter { $0.isEmpty }.count
        XCTAssertEqual(blankCount, 1)
    }

    // MARK: - 4) toolExecutionStart -> End：running... 被替换为 done/failed 占位

    func testToolExecutionReplacesRunningWithDone() {
        let renderer = TranscriptRenderer()
        renderer.apply(.toolExecutionStart(toolCallId: "tc-1", toolName: "read_file", args: "{}"))
        renderer.apply(.toolExecutionEnd(toolCallId: "tc-1", toolName: "read_file", isError: false, summary: nil))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("● read_file({})"))
        XCTAssertTrue(lines.contains("⎿ done"))
        XCTAssertFalse(lines.contains("⎿ running..."))
    }

    func testToolExecutionReplacesRunningWithFailed() {
        let renderer = TranscriptRenderer()
        renderer.apply(.toolExecutionStart(toolCallId: "tc-2", toolName: "bad_tool", args: "{}"))
        renderer.apply(.toolExecutionEnd(toolCallId: "tc-2", toolName: "bad_tool", isError: true, summary: nil))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("● bad_tool({})"))
        XCTAssertTrue(lines.contains("⎿ failed"))
        XCTAssertFalse(lines.contains("⎿ running..."))
    }

    // MARK: - 5) 多个 tool 同时 pending，各自独立替换

    func testMultiplePendingToolsReplacedIndependently() {
        let renderer = TranscriptRenderer()
        renderer.apply(.toolExecutionStart(toolCallId: "a", toolName: "toolA", args: "1"))
        renderer.apply(.toolExecutionStart(toolCallId: "b", toolName: "toolB", args: "2"))
        renderer.apply(.toolExecutionEnd(toolCallId: "a", toolName: "toolA", isError: false, summary: nil))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("⎿ done"))
        XCTAssertTrue(lines.contains("⎿ running..."))
        XCTAssertEqual(lines.filter { $0 == "⎿ done" }.count, 1)
        XCTAssertEqual(lines.filter { $0 == "⎿ running..." }.count, 1)
    }

    // MARK: - 6) 超长 summary 渲染端二次截断

    func testVeryLongSummaryIsTruncatedWithEllipsis() {
        let renderer = TranscriptRenderer()
        let veryLong = String(repeating: "x", count: 200)
        renderer.apply(.toolExecutionStart(toolCallId: "tc-long", toolName: "read", args: "{}"))
        renderer.apply(.toolExecutionEnd(toolCallId: "tc-long", toolName: "read", isError: false, summary: veryLong))

        let lines = renderer.lines.all
        let resultLine = lines.first { $0.hasPrefix("⎿ done:") }
        XCTAssertNotNil(resultLine)
        XCTAssertTrue(resultLine!.hasSuffix("..."), "Truncated summary should end with ...")
        XCTAssertLessThanOrEqual(resultLine!.count, 135, "Result line should be reasonably short after truncation")
    }

    // MARK: - 7) 120 字内 summary 不被截断

    func testShortSummaryNotTruncated() {
        let renderer = TranscriptRenderer()
        let shortSummary = String(repeating: "a", count: 100)
        renderer.apply(.toolExecutionStart(toolCallId: "tc-short", toolName: "read", args: "{}"))
        renderer.apply(.toolExecutionEnd(toolCallId: "tc-short", toolName: "read", isError: false, summary: shortSummary))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("⎿ done: \(shortSummary)"))
    }

    // MARK: - 8) pendingToolCount 追踪

    func testPendingToolCountTracksActiveTools() {
        let renderer = TranscriptRenderer()
        XCTAssertEqual(renderer.pendingToolCount, 0)

        renderer.apply(.toolExecutionStart(toolCallId: "a", toolName: "toolA", args: "1"))
        XCTAssertEqual(renderer.pendingToolCount, 1)

        renderer.apply(.toolExecutionStart(toolCallId: "b", toolName: "toolB", args: "2"))
        XCTAssertEqual(renderer.pendingToolCount, 2)

        renderer.apply(.toolExecutionEnd(toolCallId: "a", toolName: "toolA", isError: false, summary: nil))
        XCTAssertEqual(renderer.pendingToolCount, 1)

        renderer.apply(.toolExecutionEnd(toolCallId: "b", toolName: "toolB", isError: false, summary: nil))
        XCTAssertEqual(renderer.pendingToolCount, 0)
    }

    // MARK: - 9) 长->短->长 连续更新后只保留最终内容

    func testLongShortLongUpdateFinalContentOnly() {
        let renderer = TranscriptRenderer()
        renderer.apply(.messageStart(message: .assistant(text: "", errorMessage: nil)))
        renderer.apply(.messageUpdate(message: .assistant(text: "alpha\nbeta\ngamma", errorMessage: nil)))
        renderer.apply(.messageUpdate(message: .assistant(text: "x", errorMessage: nil)))
        renderer.apply(.messageUpdate(message: .assistant(text: "one\ntwo\nthree\nfour", errorMessage: nil)))
        renderer.apply(.messageEnd(message: .assistant(text: "one\ntwo\nthree\nfour", errorMessage: nil)))

        let lines = renderer.lines.all.filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["one", "two", "three", "four"])
    }

    // MARK: - 10) 空文本错误消息应可见

    func testErrorMessageShownWhenAssistantTextEmpty() {
        let renderer = TranscriptRenderer()
        renderer.apply(.messageStart(message: .assistant(text: "", errorMessage: nil)))
        renderer.apply(.messageEnd(message: .assistant(text: "", errorMessage: "OpenAI Chat Completions HTTP 404: Not Found")))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("[error] OpenAI Chat Completions HTTP 404: Not Found"))
    }
}
