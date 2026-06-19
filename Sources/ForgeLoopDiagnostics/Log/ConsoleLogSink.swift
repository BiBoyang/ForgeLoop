import Foundation

/// A `LogSystem` that writes formatted log lines to a configurable writer.
///
/// Defaults to `stderr` so that diagnostic output does not interfere with
/// TUI rendering on `stdout`.
public struct ConsoleLogSink: LogSystem {
    private let formatter: JSONLogFormatter
    private let writer: @Sendable (String) -> Void

    public init(
        formatter: JSONLogFormatter = JSONLogFormatter(),
        writer: @escaping @Sendable (String) -> Void = { fputs($0 + "\n", stderr) }
    ) {
        self.formatter = formatter
        self.writer = writer
    }

    public func log(
        level: TraceLevel,
        message: String,
        attributes: [String: TraceAttribute]
    ) async {
        let line = formatter.format(
            level: level,
            message: message,
            attributes: attributes,
            timestamp: Date()
        )
        writer(line)
    }
}
