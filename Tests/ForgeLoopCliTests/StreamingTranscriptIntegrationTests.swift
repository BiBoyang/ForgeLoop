import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli
@testable import ForgeLoopTUI

@MainActor
final class StreamingTranscriptIntegrationTests: XCTestCase {
    func testStreamingSequencePrintsPromptOnceAndAppendsOnlyNewTranscriptLines() {
        let renderer = TranscriptRenderer()
        var appendState = StreamingTranscriptAppendState()
        var emittedChunks: [[String]] = []

        func apply(_ event: AgentEvent) {
            if let coreEvent = toCoreRenderEvent(event) {
                renderer.applyCore(coreEvent)
            }
            let chunk = appendState.consume(
                transcript: renderer.transcriptLines,
                activeRange: renderer.activeStreamingRange
            )
            if !chunk.isEmpty {
                emittedChunks.append(chunk)
            }
        }

        let partial1 = assistantMessage(text: "CASE-OVERWRITE-002 行 001")
        let partial2 = assistantMessage(text: "CASE-OVERWRITE-002 行 001\nCASE-OVERWRITE-002 行 002")
        let final = assistantMessage(text: "CASE-OVERWRITE-002 行 001\nCASE-OVERWRITE-002 行 002\nCASE-OVERWRITE-002 行 003")

        apply(.messageStart(message: .user(UserMessage(text: "请只输出 260 行纯文本"))))
        apply(.messageStart(message: .assistant(assistantMessage(text: ""))))
        apply(.messageUpdate(message: partial1, assistantMessageEvent: .start(partial: partial1)))
        apply(.messageUpdate(message: partial2, assistantMessageEvent: .start(partial: partial2)))
        apply(.messageEnd(message: .assistant(final)))

        let flattened = emittedChunks.flatMap { $0 }

        XCTAssertEqual(flattened.filter { $0 == "❯ 请只输出 260 行纯文本" }.count, 1)
        XCTAssertEqual(flattened.filter { $0 == "CASE-OVERWRITE-002 行 001" }.count, 1)
        XCTAssertEqual(flattened.filter { $0 == "CASE-OVERWRITE-002 行 002" }.count, 1)
        XCTAssertEqual(flattened.filter { $0 == "CASE-OVERWRITE-002 行 003" }.count, 1)
        XCTAssertEqual(flattened, [
            "❯ 请只输出 260 行纯文本",
            "",
            "CASE-OVERWRITE-002 行 001",
            "CASE-OVERWRITE-002 行 002",
            "CASE-OVERWRITE-002 行 003",
            "",
        ])
    }
}

private func assistantMessage(text: String) -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: text))],
        stopReason: .endTurn,
        errorMessage: nil
    )
}
