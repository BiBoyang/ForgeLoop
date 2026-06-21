import Foundation

/// Aggregates a collection of concrete scorers and dispatches each assertion
/// to the first scorer that claims it can handle it.
///
/// If no scorer matches an assertion, `CompositeScorer` returns
/// `passed: false` with the message `"Unsupported assertion"`.
public struct CompositeScorer: EvalScorer {
    private let scorers: [any EvalScorer]

    /// Creates a composite scorer.
    ///
    /// - Parameter scorers: The scorers to dispatch to. Defaults to the full
    ///   set of built-in scorers.
    public init(scorers: [any EvalScorer] = CompositeScorer.defaultScorers) {
        self.scorers = scorers
    }

    public func canScore(_ assertion: EvalAssertion) -> Bool {
        scorers.contains { $0.canScore(assertion) }
    }

    public func score(assertion: EvalAssertion, workspace: Workspace) async -> AssertionResult {
        guard let scorer = scorers.first(where: { $0.canScore(assertion) }) else {
            return AssertionResult(
                assertion: assertion,
                passed: false,
                message: "Unsupported assertion"
            )
        }
        return await scorer.score(assertion: assertion, workspace: workspace)
    }

    /// The default set of built-in scorers.
    public static var defaultScorers: [any EvalScorer] {
        [
            FileContentScorer(),
            FileExistsScorer(),
            CommandOutputScorer()
        ]
    }
}
