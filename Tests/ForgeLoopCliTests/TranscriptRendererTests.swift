import XCTest
@testable import ForgeLoopTUI

@MainActor
final class TranscriptRendererTests: XCTestCase {
    // MARK: - 1) messageUpdate 覆盖：两次更新只保留后者文本

    func testStreamingUpdateReplacesPreviousContent() {
        let renderer = TranscriptRenderer()
        startAssistant(renderer)
        updateAssistant(renderer, text: "first version")
        updateAssistant(renderer, text: "second version")
        endAssistant(renderer, text: "second version")

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("second version"))
        XCTAssertFalse(lines.contains("first version"))
    }

    // MARK: - 2) 更新行数缩短：旧尾行不残留

    func testStreamingUpdateShortensLinesNoResidue() {
        let renderer = TranscriptRenderer()
        startAssistant(renderer)
        updateAssistant(renderer, text: "line1\nline2\nline3")
        updateAssistant(renderer, text: "only one")
        endAssistant(renderer, text: "only one")

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("only one"))
        XCTAssertFalse(lines.contains("line1"))
        XCTAssertFalse(lines.contains("line2"))
        XCTAssertFalse(lines.contains("line3"))
    }

    // MARK: - 3) messageEnd 后分隔空行只出现一次

    func testMessageEndAppendsSingleBlankSeparator() {
        let renderer = TranscriptRenderer()
        startAssistant(renderer)
        updateAssistant(renderer, text: "hello")
        endAssistant(renderer, text: "hello")

        let lines = renderer.transcriptLines
        let blankCount = lines.filter { $0.isEmpty }.count
        XCTAssertEqual(blankCount, 1)
    }

    // MARK: - 4) toolExecutionStart -> End：running... 被替换为 done/failed 占位

    func testToolExecutionReplacesRunningWithDone() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.operationStart(id: "tc-1", header: "● read_file({})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-1", isError: false, result: nil))

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("● read_file({})"))
        XCTAssertTrue(lines.contains("⎿ done"))
        XCTAssertFalse(lines.contains("⎿ running..."))
    }

    func testToolExecutionReplacesRunningWithFailed() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.operationStart(id: "tc-2", header: "● bad_tool({})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-2", isError: true, result: nil))

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("● bad_tool({})"))
        XCTAssertTrue(lines.contains("⎿ failed"))
        XCTAssertFalse(lines.contains("⎿ running..."))
    }

    // MARK: - 5) 多个 tool 同时 pending，各自独立替换

    func testMultiplePendingToolsReplacedIndependently() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.operationStart(id: "a", header: "● toolA(1)", status: "⎿ running..."))
        renderer.applyCore(.operationStart(id: "b", header: "● toolB(2)", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "a", isError: false, result: nil))

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("⎿ done"))
        XCTAssertTrue(lines.contains("⎿ running..."))
        XCTAssertEqual(lines.filter { $0 == "⎿ done" }.count, 1)
        XCTAssertEqual(lines.filter { $0 == "⎿ running..." }.count, 1)
    }

    // MARK: - 6) 超长 summary 渲染端二次截断

    func testVeryLongSummaryIsTruncatedWithEllipsis() {
        let renderer = TranscriptRenderer()
        let veryLong = String(repeating: "x", count: 200)
        renderer.applyCore(.operationStart(id: "tc-long", header: "● read({})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-long", isError: false, result: veryLong))

        let lines = renderer.transcriptLines
        let resultLine = lines.first { $0.hasPrefix("⎿ done:") }
        XCTAssertNotNil(resultLine)
        XCTAssertTrue(resultLine!.hasSuffix("..."), "Truncated summary should end with ...")
        XCTAssertLessThanOrEqual(resultLine!.count, 135, "Result line should be reasonably short after truncation")
    }

    // MARK: - 7) 120 字内 summary 不被截断

    func testShortSummaryNotTruncated() {
        let renderer = TranscriptRenderer()
        let shortSummary = String(repeating: "a", count: 100)
        renderer.applyCore(.operationStart(id: "tc-short", header: "● read({})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-short", isError: false, result: shortSummary))

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("⎿ done: \(shortSummary)"))
    }

    // MARK: - 8) pendingToolCount 追踪

    func testPendingToolCountTracksActiveTools() {
        let renderer = TranscriptRenderer()
        XCTAssertEqual(renderer.pendingToolCount, 0)

        renderer.applyCore(.operationStart(id: "a", header: "● toolA(1)", status: "⎿ running..."))
        XCTAssertEqual(renderer.pendingToolCount, 1)

        renderer.applyCore(.operationStart(id: "b", header: "● toolB(2)", status: "⎿ running..."))
        XCTAssertEqual(renderer.pendingToolCount, 2)

        renderer.applyCore(.operationEnd(id: "a", isError: false, result: nil))
        XCTAssertEqual(renderer.pendingToolCount, 1)

        renderer.applyCore(.operationEnd(id: "b", isError: false, result: nil))
        XCTAssertEqual(renderer.pendingToolCount, 0)
    }

    // MARK: - 9) 长->短->长 连续更新后只保留最终内容

    func testLongShortLongUpdateFinalContentOnly() {
        let renderer = TranscriptRenderer()
        startAssistant(renderer)
        updateAssistant(renderer, text: "alpha\nbeta\ngamma")
        updateAssistant(renderer, text: "x")
        updateAssistant(renderer, text: "one\ntwo\nthree\nfour")
        endAssistant(renderer, text: "one\ntwo\nthree\nfour")

        let lines = renderer.transcriptLines.filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["one", "two", "three", "four"])
    }

    // MARK: - 10) 空文本错误消息应可见

    func testErrorMessageShownWhenAssistantTextEmpty() {
        let renderer = TranscriptRenderer()
        startAssistant(renderer)
        endAssistant(renderer, text: "", errorMessage: "OpenAI Chat Completions HTTP 404: Not Found")

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("[error] OpenAI Chat Completions HTTP 404: Not Found"))
    }

    // MARK: - STEP-026) Thinking block rendering

    func testThinkingBlockRendersWithIndicator() {
        let renderer = TranscriptRenderer()
        startAssistant(renderer)
        endAssistant(renderer, text: "result", thinking: "I should think about this")

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("💭 I should think about this"))
        XCTAssertTrue(lines.contains("result"))
    }

    func testThinkingBlockCollapsedWhenMultiline() {
        let renderer = TranscriptRenderer()
        let thinking = "line one\nline two\nline three"
        startAssistant(renderer)
        endAssistant(renderer, text: "ok", thinking: thinking)

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("💭 line one …"))
        XCTAssertFalse(lines.contains("line two"))
    }

    func testNoThinkingLineWhenThinkingNil() {
        let renderer = TranscriptRenderer()
        startAssistant(renderer)
        endAssistant(renderer, text: "plain")

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("plain"))
        XCTAssertFalse(lines.contains(where: { $0.hasPrefix("💭") }))
    }

    // MARK: - STEP-026) Tool result multi-line preview + truncation

    func testToolResultMultiLinePreview() {
        let renderer = TranscriptRenderer()
        let multiLine = "line1\nline2\nline3\nline4"
        renderer.applyCore(.operationStart(id: "tc-ml", header: "● bash({})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-ml", isError: false, result: multiLine))

        let lines = renderer.transcriptLines
        let resultLines = lines.filter { $0.hasPrefix("⎿ done:") }
        XCTAssertEqual(resultLines.count, 4, "Should be 4 logical lines (3 preview + ...)")
        XCTAssertTrue(resultLines[0].contains("line1"))
        XCTAssertTrue(resultLines[1].contains("line2"))
        XCTAssertTrue(resultLines[2].contains("line3"))
        XCTAssertTrue(resultLines[3].contains("..."))
        XCTAssertFalse(lines.contains(where: { $0.contains("line4") }))
    }

    func testToolResultCharsTruncationStillApplied() {
        let renderer = TranscriptRenderer()
        let veryLong = String(repeating: "ab\n", count: 100)
        renderer.applyCore(.operationStart(id: "tc-vl", header: "● read({})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-vl", isError: false, result: veryLong))

        let lines = renderer.transcriptLines
        let resultLines = lines.filter { $0.hasPrefix("⎿ done:") }
        XCTAssertEqual(resultLines.count, 4, "Should be 4 logical lines (3 preview + ...)")
        XCTAssertTrue(resultLines.last!.hasSuffix("..."))
        for line in resultLines {
            XCTAssertLessThanOrEqual(line.count, 135, "Line '\(line)' exceeds max length")
        }
    }

    // MARK: - STEP-026) Notification folding

    func testNotificationsFoldedToMaxLines() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.notification(text: "first"))
        renderer.applyCore(.notification(text: "second"))
        renderer.applyCore(.notification(text: "third"))
        renderer.applyCore(.notification(text: "fourth"))

        let lines = renderer.transcriptLines
        let notificationCount = lines.filter { $0.hasPrefix("▸") }.count
        XCTAssertEqual(notificationCount, 3, "Should keep only latest 3 notifications")
        XCTAssertTrue(lines.contains("▸ fourth"))
    }

    // MARK: - STEP-026) Streaming long-short-long stability

    func testStreamingLongShortLongNoResidue() {
        let renderer = TranscriptRenderer()
        startAssistant(renderer)
        updateAssistant(renderer, text: "alpha\nbeta\ngamma")
        updateAssistant(renderer, text: "x")
        updateAssistant(renderer, text: "one\ntwo\nthree\nfour")
        endAssistant(renderer, text: "one\ntwo\nthree\nfour")

        let lines = renderer.transcriptLines.filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["one", "two", "three", "four"])
    }

    // MARK: - STEP-026) ToolCall deduplication via adapter

    func testAssistantContentToolCallIgnored() {
        let renderer = TranscriptRenderer()
        startAssistant(renderer)
        endAssistant(renderer, text: "I will use a tool")

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("I will use a tool"))
        XCTAssertFalse(lines.contains(where: { $0.contains("toolCall") || $0.contains("arguments") }))
    }

    // MARK: - Active Streaming Range

    func testActiveRangeSetOnBlockStart() {
        let renderer = TranscriptRenderer()
        XCTAssertNil(renderer.activeStreamingRange)

        renderer.applyCore(.blockStart(id: "a"))
        XCTAssertEqual(renderer.activeStreamingRange, 0..<0)
    }

    func testActiveRangeUpdatedOnBlockUpdate() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.blockStart(id: "a"))
        XCTAssertEqual(renderer.activeStreamingRange, 0..<0)

        renderer.applyCore(.blockUpdate(id: "a", lines: ["hello"]))
        XCTAssertEqual(renderer.activeStreamingRange, 0..<1)

        renderer.applyCore(.blockUpdate(id: "a", lines: ["hello", "world"]))
        XCTAssertEqual(renderer.activeStreamingRange, 0..<2)
    }

    func testActiveRangeClearedOnBlockEnd() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.blockStart(id: "a"))
        renderer.applyCore(.blockUpdate(id: "a", lines: ["hello"]))
        XCTAssertEqual(renderer.activeStreamingRange, 0..<1)

        renderer.applyCore(.blockEnd(id: "a", lines: ["hello"], footer: nil))
        XCTAssertNil(renderer.activeStreamingRange)
    }

    func testActiveRangeEmptyAfterBlockEndWithMultipleLines() {
        let renderer = TranscriptRenderer()
        startAssistant(renderer)
        updateAssistant(renderer, text: "line one\nline two")
        XCTAssertNotNil(renderer.activeStreamingRange)

        endAssistant(renderer, text: "line one\nline two")
        XCTAssertNil(renderer.activeStreamingRange)
    }

    // MARK: - Preferred Pinned Range (completed assistant persistence)

    func testPreferredPinnedRangeAvailableAfterBlockEnd() {
        let renderer = TranscriptRenderer()
        startAssistant(renderer)
        updateAssistant(renderer, text: "hello world")
        endAssistant(renderer, text: "hello world")

        // activeStreamingRange is nil after blockEnd
        XCTAssertNil(renderer.activeStreamingRange)
        // but preferredPinnedRange should still point to the completed block
        XCTAssertNotNil(renderer.preferredPinnedRange)
        XCTAssertEqual(renderer.preferredPinnedRange, renderer.lastCompletedAssistantRange)

        // The block was rendered as "hello world" + empty separator = 2 lines
        // But the pinned range tracks the original block position
        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("hello world"))
    }

    func testPreferredPinnedRangeSwitchesToNewActiveOnBlockStart() {
        let renderer = TranscriptRenderer()

        // First assistant block
        startAssistant(renderer, id: "first")
        updateAssistant(renderer, text: "first reply", id: "first")
        endAssistant(renderer, text: "first reply", id: "first")

        let firstRange = renderer.lastCompletedAssistantRange
        XCTAssertNotNil(firstRange)
        XCTAssertEqual(renderer.preferredPinnedRange, firstRange)

        // Second assistant block starts — preferred should switch to active
        startAssistant(renderer, id: "second")
        XCTAssertNotNil(renderer.activeStreamingRange)
        XCTAssertEqual(renderer.preferredPinnedRange, renderer.activeStreamingRange)
        // completed range from first block should still exist
        XCTAssertEqual(renderer.lastCompletedAssistantRange, firstRange)
    }

    func testInsertClearsCompletedPin() {
        let renderer = TranscriptRenderer()
        startAssistant(renderer)
        updateAssistant(renderer, text: "assistant reply")
        endAssistant(renderer, text: "assistant reply")

        XCTAssertNotNil(renderer.lastCompletedAssistantRange)
        XCTAssertNotNil(renderer.preferredPinnedRange)

        // User sends a new message (via .insert)
        renderer.applyCore(.insert(lines: ["❯ user message", ""]))

        XCTAssertNil(renderer.lastCompletedAssistantRange)
        XCTAssertNil(renderer.preferredPinnedRange)
    }

    func testCompletedRangeShiftedByNotificationFolding() {
        let renderer = TranscriptRenderer()

        // Push assistant block to higher index with notifications
        renderer.applyCore(.notification(text: "n1"))
        renderer.applyCore(.notification(text: "n2"))

        // Assistant block at index 2
        startAssistant(renderer)
        updateAssistant(renderer, text: "reply")
        endAssistant(renderer, text: "reply")

        XCTAssertEqual(renderer.lastCompletedAssistantRange, 2..<3)

        // Add more notifications, causing the oldest to be deleted and indices to shift
        renderer.applyCore(.notification(text: "n3"))
        renderer.applyCore(.notification(text: "n4"))

        // After folding (max 3 notifications), the oldest is removed and all
        // subsequent indices shift by -1. The completed range should track this.
        XCTAssertEqual(renderer.lastCompletedAssistantRange, 1..<2)
    }
}

// MARK: - Helpers

@MainActor
private func startAssistant(_ renderer: TranscriptRenderer, id: String = "__assistant") {
    renderer.applyCore(.blockStart(id: id))
}

@MainActor
private func updateAssistant(
    _ renderer: TranscriptRenderer,
    text: String,
    thinking: String? = nil,
    id: String = "__assistant"
) {
    renderer.applyCore(.blockUpdate(id: id, lines: assistantLines(text: text, thinking: thinking)))
}

@MainActor
private func endAssistant(
    _ renderer: TranscriptRenderer,
    text: String,
    thinking: String? = nil,
    errorMessage: String? = nil,
    id: String = "__assistant"
) {
    let footer = text.isEmpty ? errorMessage : nil
    renderer.applyCore(.blockEnd(id: id, lines: assistantLines(text: text, thinking: thinking), footer: footer))
}

private func assistantLines(text: String, thinking: String?) -> [String] {
    var result: [String] = []

    if let thinking, !thinking.isEmpty {
        let first = thinking.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? thinking
        let prefix = thinking.contains("\n") ? "💭 \(first) …" : "💭 \(first)"
        result.append(Style.dimmed(prefix))
    }

    if !text.isEmpty {
        result.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }

    return result
}
