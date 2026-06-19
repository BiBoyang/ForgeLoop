/// A `TraceSystem` implementation that records span lifecycle events through
/// a `LogSystem` backend.
///
/// This design lets console and file sinks receive trace data without
/// implementing a separate trace output path.
public struct LoggingTraceSystem: TraceSystem {
    private let log: LogSystem

    public init(log: LogSystem) {
        self.log = log
    }

    public func startSpan(
        name: String,
        parent: TraceContext?,
        layer: String,
        operation: String,
        attributes: [String: TraceAttribute]
    ) async -> TraceContext {
        let traceID = parent?.traceID ?? TraceIDGenerator.makeTraceID()
        let spanID = TraceIDGenerator.makeSpanID()
        let context = TraceContext(
            traceID: traceID,
            spanID: spanID,
            parentSpanID: parent?.spanID
        )

        var spanAttributes: [String: TraceAttribute] = [
            "trace_id": .string(traceID),
            "span_id": .string(spanID),
            "parent_span_id": parent.map { .string($0.spanID) } ?? .string(""),
            "layer": .string(layer),
            "operation": .string(operation)
        ]
        spanAttributes.merge(attributes) { _, new in new }

        await log.log(
            level: .debug,
            message: "span.start: \(name)",
            attributes: spanAttributes
        )

        return context
    }

    public func endSpan(
        _ context: TraceContext,
        attributes: [String: TraceAttribute],
        error: TraceError?
    ) async {
        var spanAttributes: [String: TraceAttribute] = [
            "trace_id": .string(context.traceID),
            "span_id": .string(context.spanID)
        ]
        spanAttributes.merge(attributes) { _, new in new }

        let level: TraceLevel = error != nil ? .error : .debug
        var message = "span.end: \(context.spanID)"
        if let error {
            message += " error=\(error.type)"
            spanAttributes["error_type"] = .string(error.type)
            spanAttributes["error_message"] = .string(error.message)
        }

        await log.log(level: level, message: message, attributes: spanAttributes)
    }
}
