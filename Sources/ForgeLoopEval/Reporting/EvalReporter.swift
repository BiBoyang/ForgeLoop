import Foundation

/// A strategy for rendering a collection of `EvalResult`s into a report.
///
/// Conforming types must be `Sendable` and stateless so that a single reporter
/// instance can be reused across many eval runs.
public protocol EvalReporter: Sendable {
    /// Render the given results as a report string.
    ///
    /// - Parameter results: The eval results to report.
    /// - Returns: The rendered report, e.g. JSON or Markdown text.
    func report(results: [EvalResult]) async throws -> String
}
