import Foundation

/// A named collection of eval cases that can be run together as a benchmark.
public struct BenchmarkSuite: Sendable {
    public let name: String
    public let cases: [EvalCase]

    public init(name: String, cases: [EvalCase]) {
        self.name = name
        self.cases = cases
    }
}
