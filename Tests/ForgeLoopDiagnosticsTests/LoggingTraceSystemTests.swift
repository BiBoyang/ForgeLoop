import XCTest
@testable import ForgeLoopDiagnostics

final class LoggingTraceSystemTests: XCTestCase {
    private func makeCaptureSink() -> (ConsoleLogSink, LogCapture) {
        let capture = LogCapture()
        let sink = ConsoleLogSink { line in
            capture.append(line)
        }
        return (sink, capture)
    }

    func testStartsRootSpan() async {
        let (sink, capture) = makeCaptureSink()
        let trace = LoggingTraceSystem(log: sink)

        let ctx = await trace.startSpan(
            name: "root",
            parent: nil,
            layer: "test",
            operation: "op",
            attributes: ["extra": .string("value")]
        )

        XCTAssertFalse(ctx.traceID.isEmpty)
        XCTAssertFalse(ctx.spanID.isEmpty)
        XCTAssertNil(ctx.parentSpanID)

        let lines = capture.captured
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("span.start: root"))
        XCTAssertTrue(lines[0].contains("\"layer\":\"test\""))
        XCTAssertTrue(lines[0].contains("\"extra\":\"value\""))
    }

    func testStartsChildSpan() async {
        let (sink, capture) = makeCaptureSink()
        let trace = LoggingTraceSystem(log: sink)

        let parent = await trace.startSpan(
            name: "parent",
            parent: nil,
            layer: "test",
            operation: "op",
            attributes: [:]
        )
        let child = await trace.startSpan(
            name: "child",
            parent: parent,
            layer: "test",
            operation: "op",
            attributes: [:]
        )

        XCTAssertEqual(child.traceID, parent.traceID)
        XCTAssertEqual(child.parentSpanID, parent.spanID)

        let lines = capture.captured
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("\"parent_span_id\":\"\(parent.spanID)\""))
    }

    func testLogsErrorOnEnd() async {
        let (sink, capture) = makeCaptureSink()
        let trace = LoggingTraceSystem(log: sink)

        let ctx = await trace.startSpan(
            name: "error-span",
            parent: nil,
            layer: "test",
            operation: "op",
            attributes: [:]
        )
        await trace.endSpan(
            ctx,
            attributes: [:],
            error: TraceError(type: "TestError", message: "boom")
        )

        let lines = capture.captured
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("span.end:"))
        XCTAssertTrue(lines[1].contains("\"level\":\"error\""))
        XCTAssertTrue(lines[1].contains("\"error_type\":\"TestError\""))
    }
}
