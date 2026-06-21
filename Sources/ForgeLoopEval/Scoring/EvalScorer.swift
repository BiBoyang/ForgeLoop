import Foundation

/// A strategy for scoring a single `EvalAssertion` against a workspace.
///
/// Conforming types must be `Sendable` and stateless so that a single scorer
/// instance can be reused across many eval runs.
public protocol EvalScorer: Sendable {
    /// Returns `true` if this scorer knows how to evaluate the assertion.
    func canScore(_ assertion: EvalAssertion) -> Bool

    /// Evaluate the assertion and return an `AssertionResult`.
    ///
    /// Callers should first check `canScore(_:)`. A scorer may return an
    /// unsupported-assertion result if called with an assertion it cannot handle.
    func score(assertion: EvalAssertion, workspace: Workspace) async -> AssertionResult
}
