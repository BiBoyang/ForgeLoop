/// A `TraceSystem` that discards all spans.
///
/// Use this as the default implementation to guarantee zero overhead when
/// diagnostics are not enabled.
public struct NoOpTraceSystem: TraceSystem {
    public init() {}

    public func startSpan(
        name: String,
        parent: TraceContext?,
        layer: String,
        operation: String,
        attributes: [String: TraceAttribute]
    ) async -> TraceContext {
        TraceContext(traceID: "", spanID: "", parentSpanID: nil)
    }

    public func endSpan(
        _ context: TraceContext,
        attributes: [String: TraceAttribute],
        error: TraceError?
    ) async {}
}
