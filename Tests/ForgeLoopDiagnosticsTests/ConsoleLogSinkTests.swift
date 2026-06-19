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
}
