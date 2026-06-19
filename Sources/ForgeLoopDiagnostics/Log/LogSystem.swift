/// Abstract interface for emitting structured logs.
///
/// Implementations must be `Sendable` so they can be shared across isolation
/// boundaries in Swift 6 concurrency code.
public protocol LogSystem: Sendable {
    /// Emit a log entry.
    ///
    /// - Parameters:
    ///   - level: Severity level.
    ///   - message: Human-readable message.
    ///   - attributes: Structured key-value attributes.
    func log(
        level: TraceLevel,
        message: String,
        attributes: [String: TraceAttribute]
    ) async
}
