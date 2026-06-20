import XCTest
@testable import ForgeLoopDiagnostics

final class ConsoleLogSinkTests: XCTestCase {
    func testWritesFormattedLineToWriter() async {
        let capture = LogCapture()
        let sink = ConsoleLogSink { line in
            capture.append(line)
        }

        await sink.log(
            level: .info,
            message: "hello",
            attributes: ["key": .string("value")]
        )

        let captured = capture.captured
        XCTAssertEqual(captured.count, 1)
        let line = captured[0]
        XCTAssertTrue(line.contains("\"level\":\"info\""))
        XCTAssertTrue(line.contains("\"message\":\"hello\""))
        XCTAssertTrue(line.contains("\"key\":\"value\""))
    }

    func testThrottlesDuplicateMessagesWithinOneSecond() async {
        let capture = LogCapture()
        let sink = ConsoleLogSink { line in
            capture.append(line)
        }

        await sink.log(level: .debug, message: "stream.delta", attributes: [:])
        await sink.log(level: .debug, message: "stream.delta", attributes: ["index": .int(1)])
        await sink.log(level: .debug, message: "stream.delta", attributes: ["index": .int(2)])

        let captured = capture.captured
        XCTAssertEqual(captured.count, 1, "Duplicate messages within 1s should be throttled")
        XCTAssertTrue(captured[0].contains("\"message\":\"stream.delta\""))
    }

    func testDifferentMessagesAreNotThrottled() async {
        let capture = LogCapture()
        let sink = ConsoleLogSink { line in
            capture.append(line)
        }

        await sink.log(level: .debug, message: "stream.delta", attributes: [:])
        await sink.log(level: .debug, message: "stream.done", attributes: [:])

        XCTAssertEqual(capture.captured.count, 2)
    }
}
