import XCTest
import ForgeLoopTUI

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

        XCTAssertTrue(lines.first?.hasPrefix("┌") == true)
        XCTAssertTrue(lines.contains(where: { $0.contains("name") && $0.contains("score") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("alice") && $0.contains("99") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("bob") && $0.contains("7") }))
        XCTAssertTrue(lines.last?.hasPrefix("└") == true)
        XCTAssertFalse(lines.contains("| alice | 99 |"))
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
        XCTAssertTrue(lines.first?.hasPrefix("┌") == true)
        XCTAssertTrue(lines.contains(where: { $0.contains("alice") && $0.contains("99") }))
        XCTAssertFalse(lines.contains("| alice | 99 |"))
    }

    func testStreamingEngineRendersCodeFenceWithoutParsingNestedTable() {
        let engine = StreamingMarkdownEngine()
        let text = """
        ```markdown
        | a | b |
        | --- | --- |
        | 1 | 2 |
        ```
        """

        let lines = engine.render(text: text, isFinal: true)
        XCTAssertEqual(lines, [
            "┌─ code markdown",
            "│ | a | b |",
            "│ | --- | --- |",
            "│ | 1 | 2 |",
            "└─ end code",
        ])
        XCTAssertFalse(lines.contains(where: { $0.contains("│ a │") || $0.contains("┌──") }))
    }

    func testStreamingEngineParsesEscapedPipeInCells() {
        let engine = StreamingMarkdownEngine()
        let text = """
        | col | raw |
        | --- | --- |
        | a \\| b | ok |
        """

        let lines = engine.render(text: text, isFinal: true)
        XCTAssertTrue(lines.contains(where: { $0.contains("│") && $0.contains("col") && $0.contains("raw") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("a | b") }))
    }

    func testStreamingEngineCompactsAndTruncatesVeryWideTableByDefault() {
        let engine = StreamingMarkdownEngine()
        let wideCell = String(repeating: "x", count: 260)
        let text = """
        | col | detail |
        | --- | --- |
        | ok | \(wideCell) |
        """

        let lines = engine.render(text: text, isFinal: true)
        XCTAssertTrue(lines.first?.hasPrefix("┌") == true)
        XCTAssertTrue(lines.contains(where: { $0.contains("col") && $0.contains("detail") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("…") }))
        XCTAssertTrue(lines.last?.hasPrefix("└") == true)
        XCTAssertFalse(lines.contains(where: { $0.contains(wideCell) }))
    }

    func testStreamingEngineDegradesTooManyColumnsToPlainText() {
        let engine = StreamingMarkdownEngine()
        let text = """
        | c1 | c2 | c3 | c4 | c5 | c6 | c7 | c8 | c9 | c10 | c11 | c12 | c13 | c14 | c15 | c16 |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | a | b | c | d | e | f | g | h | i | j | k | l | m | n | o | p |
        """

        let lines = engine.render(text: text, isFinal: true)
        XCTAssertEqual(lines, [
            "| c1 | c2 | c3 | c4 | c5 | c6 | c7 | c8 | c9 | c10 | c11 | c12 | c13 | c14 | c15 | c16 |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
            "| a | b | c | d | e | f | g | h | i | j | k | l | m | n | o | p |",
        ])
    }

    func testStreamingEngineKeepsInvalidDividerTableAsPlainText() {
        let engine = StreamingMarkdownEngine()
        let text = """
        | name | score |
        | nope | ---: |
        | alice | 99 |
        """

        let lines = engine.render(text: text, isFinal: true)
        XCTAssertEqual(lines, [
            "| name | score |",
            "| nope | ---: |",
            "| alice | 99 |",
        ])
    }

    func testStreamingEngineRendersCJKTableUsingVisibleWidths() {
        let engine = StreamingMarkdownEngine()
        let text = """
        | 名称 | 值 |
        | --- | --- |
        | 测试 | 甲 |
        """

        let lines = engine.render(text: text, isFinal: true)

        XCTAssertTrue(lines.first?.hasPrefix("┌") == true)
        XCTAssertTrue(lines.contains(where: { $0.contains("名称") && $0.contains("值") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("测试") && $0.contains("甲") }))
        XCTAssertTrue(lines.last?.hasPrefix("└") == true)
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

        let lines = renderer.transcriptLines
        XCTAssertTrue(lines.contains(where: { $0.contains("💭 preparing table") }))
        XCTAssertTrue(lines.contains(where: { $0.hasPrefix("┌") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("a") && $0.contains("b") && $0.contains("│") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("1") && $0.contains("2") && $0.contains("│") }))
    }
}
