import Foundation

/// The result of running a single eval case.
public struct EvalResult: Sendable, Codable, Equatable {
    public let caseID: String
    public let passed: Bool
    public let score: Double
    public let duration: Duration
    public let assertionResults: [AssertionResult]

    public init(
        caseID: String,
        passed: Bool,
        score: Double,
        duration: Duration,
        assertionResults: [AssertionResult] = []
    ) {
        self.caseID = caseID
        self.passed = passed
        self.score = score
        self.duration = duration
        self.assertionResults = assertionResults
    }
}

/// The outcome of checking a single assertion.
public struct AssertionResult: Sendable, Codable, Equatable {
    public let assertion: EvalAssertion
    public let passed: Bool
    public let message: String

    public init(assertion: EvalAssertion, passed: Bool, message: String) {
        self.assertion = assertion
        self.passed = passed
        self.message = message
    }
}
