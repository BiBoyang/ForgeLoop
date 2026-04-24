import XCTest
@testable import ForgeLoopTUI

final class MarkdownEngineTests: XCTestCase {
    func testPlainTextEngineSplitsByNewline() {
        let engine = PlainTextMarkdownEngine()
        let lines = engine.render(text: "alpha\nbeta\n", isFinal: true)
        XCTAssertEqual(lines, ["alpha", "beta", ""])
    }

    func testStreamingEngineRendersCompleteTable() {
        let engine = StreamingMarkdownEngine()
        let text = """
        | name | score |
        | --- | ---: |
        | alice | 99 |
        | bob | 7 |
        """
        let lines = engine.render(text: text, isFinal: true)

        XCTAssertTrue(lines.contains("┌───────┬───────┐"))
        XCTAssertTrue(lines.contains("│ name  │ score │"))
        XCTAssertTrue(lines.contains("│ alice │    99 │"))
        XCTAssertTrue(lines.contains("│ bob   │     7 │"))
        XCTAssertTrue(lines.contains("└───────┴───────┘"))
    }

    func testStreamingEngineKeepsIncompleteTableAsPlainTextWhenNotFinal() {
        let engine = StreamingMarkdownEngine()
        let text = """
        | name | score |
        | --- | ---: |
        | alice
        """
        let lines = engine.render(text: text, isFinal: false)
        XCTAssertEqual(lines, ["| name | score |", "| --- | ---: |", "| alice"])
    }

    func testStreamingEngineConvergesToTableOnFinalFlush() {
        let engine = StreamingMarkdownEngine()
        let partial = """
        | name | score |
        | --- | ---: |
        | alice
        """
        _ = engine.render(text: partial, isFinal: false)

        let completed = """
        | name | score |
        | --- | ---: |
        | alice | 99 |
        """
        let lines = engine.render(text: completed, isFinal: true)
        XCTAssertTrue(lines.contains("┌───────┬───────┐"))
        XCTAssertTrue(lines.contains("│ alice │    99 │"))
        XCTAssertFalse(lines.contains("| alice | 99 |"))
    }
}

@MainActor
final class TranscriptRendererMarkdownTests: XCTestCase {
    func testTranscriptRendererRendersThinkingAndTableTogether() {
        let renderer = TranscriptRenderer()

        renderer.applyCore(.blockStart(id: "assistant"))
        renderer.applyCore(.blockUpdate(
            id: "assistant",
            lines: [
                Style.dimmed("💭 preparing table"),
                "| a | b |",
                "| --- | --- |",
                "| 1 | 2 |",
            ]
        ))
        renderer.applyCore(.blockEnd(
            id: "assistant",
            lines: [
                Style.dimmed("💭 preparing table"),
                "| a | b |",
                "| --- | --- |",
                "| 1 | 2 |",
            ],
            footer: nil
        ))

        let lines = renderer.lines.all
        XCTAssertTrue(lines.contains(where: { $0.contains("💭 preparing table") }))
        XCTAssertTrue(lines.contains("┌───┬───┐"))
        XCTAssertTrue(lines.contains("│ a │ b │"))
        XCTAssertTrue(lines.contains("│ 1 │ 2 │"))
    }
}
