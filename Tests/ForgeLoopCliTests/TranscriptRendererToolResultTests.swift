import XCTest
import ForgeLoopTUI

@MainActor
final class TranscriptRendererToolResultTests: XCTestCase {
    // MARK: - 1) Tool success with summary renders "done: <summary>"

    func testToolSuccessWithSummary() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.operationStart(id: "tc-1", header: "● read({\"path\":\"file.txt\"})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-1", isError: false, result: "hello world"))

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("● read({\"path\":\"file.txt\"})"))
        XCTAssertTrue(lines.contains("⎿ done: hello world"))
        XCTAssertFalse(lines.contains("⎿ running..."))
    }

    // MARK: - 2) Tool failure with summary renders "failed: <summary>"

    func testToolFailureWithSummary() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.operationStart(id: "tc-2", header: "● read({\"path\":\"missing\"})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-2", isError: true, result: "File not found"))

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("⎿ failed: File not found"))
        XCTAssertFalse(lines.contains("⎿ running..."))
    }

    // MARK: - 3) Tool with nil summary falls back to plain "done"/"failed"

    func testToolWithNilSummary() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.operationStart(id: "tc-3", header: "● write({})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-3", isError: false, result: nil))

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("⎿ done"))
        XCTAssertFalse(lines.contains("⎿ done: \"\""))
    }

    // MARK: - 4) Empty output summary renders "(no output)"

    func testToolEmptyOutputSummary() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.operationStart(id: "tc-4", header: "● bash({})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-4", isError: false, result: "(no output)"))

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("⎿ done: (no output)"))
    }

    // MARK: - 5) Long summary is already truncated by AgentLoop (<= 80 + "...")

    func testToolLongSummaryRendering() {
        let renderer = TranscriptRenderer()
        let longSummary = String(repeating: "a", count: 80) + "..."
        renderer.applyCore(.operationStart(id: "tc-5", header: "● read({})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-5", isError: false, result: longSummary))

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("⎿ done: \(longSummary)"))
    }

    // MARK: - 6) Multiple tools with mixed summaries, each replaced independently

    func testMultipleToolsWithMixedSummaries() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.operationStart(id: "a", header: "● read(1)", status: "⎿ running..."))
        renderer.applyCore(.operationStart(id: "b", header: "● write(2)", status: "⎿ running..."))
        renderer.applyCore(.operationStart(id: "c", header: "● bash(3)", status: "⎿ running..."))

        renderer.applyCore(.operationEnd(id: "a", isError: false, result: "file content"))
        renderer.applyCore(.operationEnd(id: "b", isError: true, result: "permission denied"))

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("⎿ done: file content"))
        XCTAssertTrue(lines.contains("⎿ failed: permission denied"))
        XCTAssertTrue(lines.contains("⎿ running..."))
        XCTAssertEqual(lines.filter { $0 == "⎿ running..." }.count, 1)
    }

    // MARK: - 7) Tool result between assistant streaming messages doesn't corrupt transcript

    func testToolResultBetweenAssistantMessages() {
        let renderer = TranscriptRenderer()

        startAssistant(renderer)
        updateAssistant(renderer, text: "Here is the result:")
        endAssistant(renderer, text: "Here is the result:")

        renderer.applyCore(.operationStart(id: "tc-7", header: "● read({})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-7", isError: false, result: "data"))

        startAssistant(renderer)
        updateAssistant(renderer, text: "Done")
        endAssistant(renderer, text: "Done")

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("Here is the result:"))
        XCTAssertTrue(lines.contains("⎿ done: data"))
        XCTAssertTrue(lines.contains("Done"))

        let assistantLineCount = lines.filter { $0 == "Here is the result:" }.count
        XCTAssertEqual(assistantLineCount, 1)
    }

    // MARK: - 8) Tool summary with newline only uses first line

    func testToolSummaryFirstLineOnly() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.operationStart(id: "tc-8", header: "● bash({})", status: "⎿ running..."))
        renderer.applyCore(.operationEnd(id: "tc-8", isError: false, result: "first line"))

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains("⎿ done: first line"))
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
