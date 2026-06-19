import XCTest
@testable import ForgeLoopDiagnostics

final class DiagnosticsTests: XCTestCase {
    func testNoOpTraceSystemDoesNotCrash() async {
        let trace = NoOpTraceSystem()
        let ctx = await trace.startSpan(
            name: "test",
            parent: nil,
            layer: "test",
            operation: "op",
            attributes: [:]
        )
        await trace.endSpan(ctx, attributes: [:], error: nil)
    }

    func testNoOpLogSystemDoesNotCrash() async {
        let log = NoOpLogSystem()
        await log.log(level: .info, message: "hello", attributes: [:])
    }

    func testDiagnosticsDefaultsToNoOp() async {
        let diagnostics = Diagnostics()
        let ctx = await diagnostics.trace.startSpan(
            name: "default",
            parent: nil,
            layer: "test",
            operation: "op",
            attributes: [:]
        )
        await diagnostics.trace.endSpan(ctx, attributes: [:], error: nil)
        await diagnostics.log.log(level: .debug, message: "noop", attributes: [:])
    }

    func testTraceContextIsSendable() {
        let ctx = TraceContext(traceID: "t1", spanID: "s1", parentSpanID: "p1")
        XCTAssertEqual(ctx.traceID, "t1")
        XCTAssertEqual(ctx.spanID, "s1")
        XCTAssertEqual(ctx.parentSpanID, "p1")
    }

    func testTraceErrorCreation() {
        let error = TraceError(type: "TestError", message: "something went wrong")
        XCTAssertEqual(error.type, "TestError")
        XCTAssertEqual(error.message, "something went wrong")
    }
}
