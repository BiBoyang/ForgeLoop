import XCTest
@testable import ForgeLoopTUI

final class StreamingTranscriptAppendStateTests: XCTestCase {
    func testConsumeAppendsStablePrefixBeforeStreamingBlock() {
        var state = StreamingTranscriptAppendState()
        let transcript = ["❯ prompt", "", "partial"]

        let emitted = state.consume(transcript: transcript, activeRange: 2..<3)

        XCTAssertEqual(emitted, ["❯ prompt", ""])
    }

    func testConsumeDoesNotRepeatGrowingPartialLine() {
        var state = StreamingTranscriptAppendState()

        let first = state.consume(transcript: ["❯ prompt", "", "C"], activeRange: 2..<3)
        let second = state.consume(transcript: ["❯ prompt", "", "CASE"], activeRange: 2..<3)

        XCTAssertEqual(first, ["❯ prompt", ""])
        XCTAssertEqual(second, [])
    }

    func testConsumeAppendsCompletedStreamingLinesOnce() {
        var state = StreamingTranscriptAppendState()

        _ = state.consume(transcript: ["❯ prompt", "", "line1"], activeRange: 2..<3)
        let emitted = state.consume(transcript: ["❯ prompt", "", "line1", "partial"], activeRange: 2..<4)

        XCTAssertEqual(emitted, ["line1"])
    }

    func testConsumeFlushesRemainingLinesWhenStreamingEnds() {
        var state = StreamingTranscriptAppendState()

        let duringStreaming = state.consume(transcript: ["❯ prompt", "", "line1", "partial"], activeRange: 2..<4)
        let emitted = state.consume(transcript: ["❯ prompt", "", "line1", "partial", ""], activeRange: nil)

        XCTAssertEqual(duringStreaming, ["❯ prompt", "", "line1"])
        XCTAssertEqual(emitted, ["partial", ""])
    }
}
