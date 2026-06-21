import Foundation

/// Renders eval results as a structured JSON report.
///
/// The output follows the `EvalReport` schema (v1.0), which is stable for CI
/// parsing. Durations are emitted as `durationMs` integers for readability and
/// portability.
public struct JSONEvalReporter: EvalReporter {
    private let encoder: JSONEncoder

    public init(encoder: JSONEncoder = JSONEvalReporter.makeDefaultEncoder()) {
        self.encoder = encoder
    }

    public func report(results: [EvalResult]) async throws -> String {
        let report = EvalReport(results: results)
        let data = try encoder.encode(report)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EvalReporterError.encodingFailed
        }
        return string
    }

    /// Creates a default JSON encoder with sorted keys, pretty printing, and
    /// ISO8601 date encoding.
    public static func makeDefaultEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
