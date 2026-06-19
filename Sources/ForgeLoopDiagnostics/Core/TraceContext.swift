/// Identifies a single trace span within a distributed trace.
public struct TraceContext: Sendable {
    public let traceID: String
    public let spanID: String
    public let parentSpanID: String?

    public init(traceID: String, spanID: String, parentSpanID: String? = nil) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
    }
}
