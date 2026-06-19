/// Facade that groups the trace and log systems used by ForgeLoop.
///
/// Defaults to no-op implementations, so consumers pay no cost unless they
/// explicitly inject a real backend.
public struct Diagnostics: Sendable {
    public let trace: TraceSystem
    public let log: LogSystem

    public init(
        trace: TraceSystem = NoOpTraceSystem(),
        log: LogSystem = NoOpLogSystem()
    ) {
        self.trace = trace
        self.log = log
    }
}
