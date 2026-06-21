import Foundation
import ForgeLoopAI

/// Runs a `BenchmarkSuite` deterministically by registering a per-case
/// `FauxProvider` and unregistering it after each run.
///
/// This avoids real LLM calls and keeps nightly CI reproducible. If any case
/// lacks a deterministic provider mapping, the runner records a failing result
/// with a clear message instead of falling back to an unconfigured provider.
public struct DeterministicRunner: Sendable {
    public init() {}

    /// Run every case in `suite` and return the collected `EvalResult`s.
    public func run(_ suite: BenchmarkSuite) async -> [EvalResult] {
        var results: [EvalResult] = []
        for evalCase in suite.cases {
            let result = await run(evalCase)
            results.append(result)
        }
        return results
    }

    private func run(_ evalCase: EvalCase) async -> EvalResult {
        let apiName = "deterministic-\(evalCase.id)-\(UUID().uuidString)"
        guard let provider = DeterministicProvider.make(for: evalCase, api: apiName) else {
            return EvalResult(
                caseID: evalCase.id,
                passed: false,
                score: 0.0,
                duration: .seconds(0),
                assertionResults: [
                    AssertionResult(
                        assertion: .fileExists(path: "<deterministic-mapping>"),
                        passed: false,
                        message: "No deterministic provider mapping for case \(evalCase.id)"
                    )
                ]
            )
        }

        let sourceId = "deterministic-runner-\(evalCase.id)-\(UUID().uuidString)"
        await APIRegistry.shared.register(provider, sourceId: sourceId)
        let runner = EvalRunner(config: EvalConfig(providerName: apiName))
        let result = await runner.run(evalCase)
        await APIRegistry.shared.unregisterSource(sourceId)
        return result
    }
}
