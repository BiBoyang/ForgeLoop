import Foundation

/// A structured, serializable report aggregating a collection of `EvalResult`s.
///
/// `EvalReport` is the shared intermediate representation used by both
/// `JSONEvalReporter` and `MarkdownEvalReporter`. It normalizes durations to
/// milliseconds and computes summary statistics so that reporters do not
/// duplicate aggregation logic.
public struct EvalReport: Sendable, Codable {
    public let schemaVersion: String
    public let generatedAt: String
    public let summary: EvalReportSummary
    public let results: [EvalReportResult]

    public init(results: [EvalResult]) {
        self.schemaVersion = "1.0"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.generatedAt = formatter.string(from: Date())
        self.summary = EvalReportSummary(results: results)
        self.results = results.map(EvalReportResult.init)
    }
}

public struct EvalReportSummary: Sendable, Codable {
    public let totalCases: Int
    public let passedCases: Int
    public let failedCases: Int
    public let averageScore: Double
    public let averageDurationMs: Int

    public init(results: [EvalResult]) {
        self.totalCases = results.count
        self.passedCases = results.filter(\.passed).count
        self.failedCases = totalCases - passedCases
        self.averageScore = results.isEmpty
            ? 0.0
            : results.map(\.score).reduce(0, +) / Double(results.count)
        self.averageDurationMs = results.isEmpty
            ? 0
            : Int(results.map(\.duration.milliseconds).reduce(0, +) / Double(results.count))
    }
}

public struct EvalReportResult: Sendable, Codable {
    public let caseID: String
    public let passed: Bool
    public let score: Double
    public let durationMs: Int
    public let assertionResults: [AssertionResult]

    public init(result: EvalResult) {
        self.caseID = result.caseID
        self.passed = result.passed
        self.score = result.score
        self.durationMs = Int(result.duration.milliseconds)
        self.assertionResults = result.assertionResults
    }
}

extension Duration {
    /// Converts the duration to fractional milliseconds.
    var milliseconds: Double {
        let components = self.components
        let secondsPart = Double(components.seconds) * 1000.0
        let attosecondsPart = Double(components.attoseconds) / 1_000_000_000_000_000.0
        return secondsPart + attosecondsPart
    }
}
