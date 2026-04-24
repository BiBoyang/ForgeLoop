import XCTest
import ForgeLoopTUI
@testable import ForgeLoopCli

@MainActor
final class MarkdownRenderOptionsTests: XCTestCase {
    func testForgeLoopMarkdownRenderOptionsUseApplicationPolicy() {
        let options = forgeLoopMarkdownRenderOptions()

        XCTAssertEqual(options.tablePolicy.maxRenderedWidth, 80)
        XCTAssertEqual(options.tablePolicy.minColumnWidth, 4)
        XCTAssertEqual(options.tablePolicy.maxColumnWidth, 28)
        XCTAssertEqual(options.tablePolicy.truncationIndicator, "...")
        XCTAssertEqual(options.tablePolicy.overflowBehavior, .compactThenTruncateThenDegrade)
    }

    func testForgeLoopMarkdownRenderOptionsProduceASCIIDotTruncation() {
        let renderer = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())

        renderer.applyCore(.blockStart(id: "assistant"))
        renderer.applyCore(.blockEnd(
            id: "assistant",
            lines: [
                "| column | detail |",
                "| --- | --- |",
                "| ok | \(String(repeating: "x", count: 260)) |",
            ],
            footer: nil
        ))

        XCTAssertTrue(renderer.transcriptLines.contains(where: { $0.contains("...") }))
    }
}
