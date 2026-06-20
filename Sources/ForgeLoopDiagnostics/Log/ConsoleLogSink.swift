import Foundation

/// Thread-safe state for per-message console log throttling.
private final class ThrottleState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastKey: String?
    private var lastTimestamp: Date?

    /// Returns `true` if the message should be printed and updates the throttle state.
    func shouldPrint(key: String, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let lastKey = lastKey, lastKey == key, let lastTimestamp = lastTimestamp,
           now.timeIntervalSince(lastTimestamp) < 1.0 {
            return false
        }
        self.lastKey = key
        self.lastTimestamp = now
        return true
    }
}

/// A `LogSystem` that writes formatted log lines to a configurable writer.
///
/// Defaults to `stderr` so that diagnostic output does not interfere with
/// TUI rendering on `stdout`.
///
/// Identical messages are throttled to once per second to avoid flooding
/// the console during high-frequency events such as streaming text deltas.
public struct ConsoleLogSink: LogSystem {
    private let formatter: JSONLogFormatter
    private let writer: @Sendable (String) -> Void
    private let throttle: ThrottleState

    public init(
        formatter: JSONLogFormatter = JSONLogFormatter(),
        writer: @escaping @Sendable (String) -> Void = { fputs($0 + "\n", stderr) }
    ) {
        self.formatter = formatter
        self.writer = writer
        self.throttle = ThrottleState()
    }

    public func log(
        level: TraceLevel,
        message: String,
        attributes: [String: TraceAttribute]
    ) async {
        let now = Date()
        guard throttle.shouldPrint(key: message, now: now) else { return }
        let line = formatter.format(
            level: level,
            message: message,
            attributes: attributes,
            timestamp: now
        )
        writer(line)
    }
}
