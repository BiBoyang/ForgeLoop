/// A `LogSystem` that discards all log entries.
///
/// Use this as the default implementation to guarantee zero overhead when
/// diagnostics are not enabled.
public struct NoOpLogSystem: LogSystem {
    public init() {}

    public func log(
        level: TraceLevel,
        message: String,
        attributes: [String: TraceAttribute]
    ) async {}
}
