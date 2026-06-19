/// Abstract interface for emitting distributed traces.
///
/// Implementations must be `Sendable` so they can be shared across isolation
/// boundaries in Swift 6 concurrency code.
public protocol TraceSystem: Sendable {
    /// Start a new span and return its context.
    ///
    /// - Parameters:
    ///   - name: Human-readable span name.
    ///   - parent: Optional parent context; `nil` starts a new trace.
    ///   - layer: Architectural layer (e.g. "AI", "Agent", "Cli").
    ///   - operation: Operation identifier (e.g. "sendRequest").
    ///   - attributes: Initial span attributes.
    func startSpan(
        name: String,
        parent: TraceContext?,
        layer: String,
        operation: String,
        attributes: [String: TraceAttribute]
    ) async -> TraceContext

    /// End a span, optionally recording additional attributes or an error.
    func endSpan(
        _ context: TraceContext,
        attributes: [String: TraceAttribute],
        error: TraceError?
    ) async
}
