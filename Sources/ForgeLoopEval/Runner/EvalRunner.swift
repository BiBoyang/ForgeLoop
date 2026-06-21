import Foundation
import ForgeLoopDiagnostics

/// Orchestrates the execution of a single `EvalCase`.
///
/// `EvalRunner` is a plain `Sendable` struct with no mutable state. It creates a
/// temporary `Workspace`, writes the case's initial files, drives the agent via
/// `AgentDriver`, scores assertions through the injected `EvalScorer`, and cleans
/// up. The run itself is traced through the injected `Diagnostics` facade.
public struct EvalRunner: Sendable {
    public let config: EvalConfig
    public let diagnostics: Diagnostics
    public let scorer: any EvalScorer

    public init(
        config: EvalConfig = EvalConfig(),
        diagnostics: Diagnostics = Diagnostics(),
        scorer: any EvalScorer = CompositeScorer()
    ) {
        self.config = config
        self.diagnostics = diagnostics
        self.scorer = scorer
    }

    /// Run a single eval case and return an `EvalResult`.
    ///
    /// The workspace is always created under `FileManager.default.temporaryDirectory`.
    /// Cleanup is performed by default; pass `shouldCleanup: false` to keep it.
    public func run(
        _ evalCase: EvalCase,
        shouldCleanup: Bool = true
    ) async -> EvalResult {
        let workspace: Workspace
        do {
            workspace = try await Workspace.makeTemporary(
                prefix: "ForgeLoopEval-\(evalCase.id)",
                shouldCleanup: shouldCleanup
            )
        } catch {
            return EvalResult(
                caseID: evalCase.id,
                passed: false,
                score: 0,
                duration: .seconds(0),
                assertionResults: []
            )
        }

        let runSpan = await diagnostics.trace.startSpan(
            name: "eval.run",
            parent: nil,
            layer: "Eval",
            operation: "run",
            attributes: [
                "case_id": .string(evalCase.id),
                "provider": .string(config.providerName)
            ]
        )

        let start = ContinuousClock().now
        let timeout = evalCase.timeout > .seconds(0) ? evalCase.timeout : config.defaultTimeout

        do {
            try await workspace.write(files: evalCase.initialFiles)

            let driver = AgentDriver(diagnostics: diagnostics)
            let driverResult = try await runWithTimeout(
                timeout: timeout,
                body: {
                    await driver.run(
                        case: evalCase,
                        workspace: workspace,
                        config: config
                    )
                }
            )

            let duration = ContinuousClock().now - start
            var assertionResults: [AssertionResult] = []
            for assertion in evalCase.assertions {
                let result = await scorer.score(
                    assertion: assertion,
                    workspace: workspace
                )
                assertionResults.append(result)
            }
            let allPassed = assertionResults.allSatisfy(\.passed)
            let passed = driverResult.error == nil && allPassed

            var traceError: TraceError?
            if let error = driverResult.error {
                traceError = TraceError(
                    type: String(describing: type(of: error)),
                    message: "\(error)"
                )
            } else if !allPassed {
                traceError = TraceError(
                    type: "AssertionFailure",
                    message: "One or more assertions failed"
                )
            }

            await diagnostics.trace.endSpan(
                runSpan,
                attributes: [
                    "passed": .bool(passed)
                ],
                error: traceError
            )

            if shouldCleanup {
                try? await workspace.cleanup()
            }

            return EvalResult(
                caseID: evalCase.id,
                passed: passed,
                score: passed ? 1.0 : 0.0,
                duration: duration,
                assertionResults: assertionResults
            )
        } catch is EvalTimeoutError {
            let duration = ContinuousClock().now - start
            await diagnostics.trace.endSpan(
                runSpan,
                attributes: [
                    "passed": .bool(false),
                    "timeout": .bool(true)
                ],
                error: TraceError(
                    type: "EvalTimeout",
                    message: "Eval timed out after \(timeout.components.seconds)s"
                )
            )

            if shouldCleanup {
                try? await workspace.cleanup()
            }

            return EvalResult(
                caseID: evalCase.id,
                passed: false,
                score: 0.0,
                duration: duration,
                assertionResults: []
            )
        } catch {
            let duration = ContinuousClock().now - start
            await diagnostics.trace.endSpan(
                runSpan,
                attributes: [
                    "passed": .bool(false)
                ],
                error: TraceError(
                    type: String(describing: type(of: error)),
                    message: "\(error)"
                )
            )

            if shouldCleanup {
                try? await workspace.cleanup()
            }

            return EvalResult(
                caseID: evalCase.id,
                passed: false,
                score: 0.0,
                duration: duration,
                assertionResults: []
            )
        }
    }

}

/// Marker error thrown when an eval run exceeds its timeout.
private struct EvalTimeoutError: Error {}

/// Run an async body with a timeout, cancelling the task if it expires.
private func runWithTimeout<T: Sendable>(
    timeout: Duration,
    body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await body()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw EvalTimeoutError()
        }
        guard let result = try await group.next() else {
            group.cancelAll()
            throw EvalTimeoutError()
        }
        group.cancelAll()
        return result
    }
}
