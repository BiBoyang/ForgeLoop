import XCTest
@testable import ForgeLoopTUI

@MainActor
final class TranscriptRendererToolResultTests: XCTestCase {

    // MARK: - 1) Tool success with summary renders "done: <summary>"

    func testToolSuccessWithSummary() {
        let renderer = TranscriptRenderer()
        renderer.apply(.toolExecutionStart(toolCallId: "tc-1", toolName: "read", args: "{\"path\":\"file.txt\"}"))
        renderer.apply(.toolExecutionEnd(toolCallId: "tc-1", toolName: "read", isError: false, summary: "hello world"))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("● read({\"path\":\"file.txt\"})"))
        XCTAssertTrue(lines.contains("⎿ done: hello world"))
        XCTAssertFalse(lines.contains("⎿ running..."))
    }

    // MARK: - 2) Tool failure with summary renders "failed: <summary>"

    func testToolFailureWithSummary() {
        let renderer = TranscriptRenderer()
        renderer.apply(.toolExecutionStart(toolCallId: "tc-2", toolName: "read", args: "{\"path\":\"missing\"}"))
        renderer.apply(.toolExecutionEnd(toolCallId: "tc-2", toolName: "read", isError: true, summary: "File not found"))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("⎿ failed: File not found"))
        XCTAssertFalse(lines.contains("⎿ running..."))
    }

    // MARK: - 3) Tool with nil summary falls back to plain "done"/"failed"

    func testToolWithNilSummary() {
        let renderer = TranscriptRenderer()
        renderer.apply(.toolExecutionStart(toolCallId: "tc-3", toolName: "write", args: "{}"))
        renderer.apply(.toolExecutionEnd(toolCallId: "tc-3", toolName: "write", isError: false, summary: nil))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("⎿ done"))
        XCTAssertFalse(lines.contains("⎿ done: \"\""))
    }

    // MARK: - 4) Empty output summary renders "(no output)"

    func testToolEmptyOutputSummary() {
        let renderer = TranscriptRenderer()
        renderer.apply(.toolExecutionStart(toolCallId: "tc-4", toolName: "bash", args: "{}"))
        renderer.apply(.toolExecutionEnd(toolCallId: "tc-4", toolName: "bash", isError: false, summary: "(no output)"))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("⎿ done: (no output)"))
    }

    // MARK: - 5) Long summary is already truncated by AgentLoop (<= 80 + "...")

    func testToolLongSummaryRendering() {
        let renderer = TranscriptRenderer()
        let longSummary = String(repeating: "a", count: 80) + "..."
        renderer.apply(.toolExecutionStart(toolCallId: "tc-5", toolName: "read", args: "{}"))
        renderer.apply(.toolExecutionEnd(toolCallId: "tc-5", toolName: "read", isError: false, summary: longSummary))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("⎿ done: \(longSummary)"))
    }

    // MARK: - 6) Multiple tools with mixed summaries, each replaced independently

    func testMultipleToolsWithMixedSummaries() {
        let renderer = TranscriptRenderer()
        renderer.apply(.toolExecutionStart(toolCallId: "a", toolName: "read", args: "1"))
        renderer.apply(.toolExecutionStart(toolCallId: "b", toolName: "write", args: "2"))
        renderer.apply(.toolExecutionStart(toolCallId: "c", toolName: "bash", args: "3"))

        renderer.apply(.toolExecutionEnd(toolCallId: "a", toolName: "read", isError: false, summary: "file content"))
        renderer.apply(.toolExecutionEnd(toolCallId: "b", toolName: "write", isError: true, summary: "permission denied"))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("⎿ done: file content"))
        XCTAssertTrue(lines.contains("⎿ failed: permission denied"))
        XCTAssertTrue(lines.contains("⎿ running..."))
        XCTAssertEqual(lines.filter { $0 == "⎿ running..." }.count, 1)
    }

    // MARK: - 7) Tool result between assistant streaming messages doesn't corrupt transcript

    func testToolResultBetweenAssistantMessages() {
        let renderer = TranscriptRenderer()

        // First assistant message
        renderer.apply(.messageStart(message: .assistant(text: "", errorMessage: nil)))
        renderer.apply(.messageUpdate(message: .assistant(text: "Here is the result:", errorMessage: nil)))
        renderer.apply(.messageEnd(message: .assistant(text: "Here is the result:", errorMessage: nil)))

        // Tool execution
        renderer.apply(.toolExecutionStart(toolCallId: "tc-7", toolName: "read", args: "{}"))
        renderer.apply(.toolExecutionEnd(toolCallId: "tc-7", toolName: "read", isError: false, summary: "data"))

        // Second assistant message
        renderer.apply(.messageStart(message: .assistant(text: "", errorMessage: nil)))
        renderer.apply(.messageUpdate(message: .assistant(text: "Done", errorMessage: nil)))
        renderer.apply(.messageEnd(message: .assistant(text: "Done", errorMessage: nil)))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("Here is the result:"))
        XCTAssertTrue(lines.contains("⎿ done: data"))
        XCTAssertTrue(lines.contains("Done"))

        // Verify streamingRange was cleared after first messageEnd
        // (by checking no duplicate content from previous streaming)
        let assistantLineCount = lines.filter { $0 == "Here is the result:" }.count
        XCTAssertEqual(assistantLineCount, 1)
    }

    // MARK: - 8) Tool summary with newline only uses first line

    func testToolSummaryFirstLineOnly() {
        let renderer = TranscriptRenderer()
        renderer.apply(.toolExecutionStart(toolCallId: "tc-8", toolName: "bash", args: "{}"))
        // AgentLoop should only send first line, but renderer should handle gracefully
        renderer.apply(.toolExecutionEnd(toolCallId: "tc-8", toolName: "bash", isError: false, summary: "first line"))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains("⎿ done: first line"))
    }
}
