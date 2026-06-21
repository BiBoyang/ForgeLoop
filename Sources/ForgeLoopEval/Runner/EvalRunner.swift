import Foundation
import ForgeLoopDiagnostics

/// Orchestrates the execution of a single `EvalCase`.
///
/// `EvalRunner` is a plain `Sendable` struct with no mutable state. It creates a
/// temporary `Workspace`, writes the case's initial files, drives the agent via
/// `AgentDriver`, evaluates assertions, and cleans up. The run itself is traced
/// through the injected `Diagnostics` facade.
public struct EvalRunner: Sendable {
    public let config: EvalConfig
    public let diagnostics: Diagnostics

    public init(
        config: EvalConfig = EvalConfig(),
        diagnostics: Diagnostics = Diagnostics()
    ) {
        self.config = config
        self.diagnostics = diagnostics
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
            let assertionResults = await evaluate(
                assertions: evalCase.assertions,
                workspace: workspace
            )
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

    /// Evaluate a list of assertions against the workspace.
    private func evaluate(
        assertions: [EvalAssertion],
        workspace: Workspace
    ) async -> [AssertionResult] {
        var results: [AssertionResult] = []
        for assertion in assertions {
            let result = await evaluate(assertion: assertion, workspace: workspace)
            results.append(result)
        }
        return results
    }

    /// Evaluate a single assertion.
    private func evaluate(
        assertion: EvalAssertion,
        workspace: Workspace
    ) async -> AssertionResult {
        let rootURL = await workspace.rootURL
        switch assertion {
        case .fileExists(let path):
            let url = rootURL.appendingPathComponent(path)
            let exists = FileManager.default.fileExists(atPath: url.path)
            return AssertionResult(
                assertion: assertion,
                passed: exists,
                message: exists ? "File exists: \(path)" : "File not found: \(path)"
            )
        case .fileContains(let path, let substring):
            let url = rootURL.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return AssertionResult(
                    assertion: assertion,
                    passed: false,
                    message: "File not found: \(path)"
                )
            }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                return AssertionResult(
                    assertion: assertion,
                    passed: false,
                    message: "Could not read file: \(path)"
                )
            }
            let passed = content.contains(substring)
            return AssertionResult(
                assertion: assertion,
                passed: passed,
                message: passed
                    ? "File \(path) contains '\(substring)'"
                    : "File \(path) does not contain '\(substring)'"
            )
        case .fileNotContains(let path, let substring):
            let url = rootURL.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return AssertionResult(
                    assertion: assertion,
                    passed: false,
                    message: "File not found: \(path)"
                )
            }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                return AssertionResult(
                    assertion: assertion,
                    passed: false,
                    message: "Could not read file: \(path)"
                )
            }
            let passed = !content.contains(substring)
            return AssertionResult(
                assertion: assertion,
                passed: passed,
                message: passed
                    ? "File \(path) does not contain '\(substring)'"
                    : "File \(path) contains '\(substring)'"
            )
        case .fileEquals(let path, let expected):
            let url = rootURL.appendingPathComponent(path)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                return AssertionResult(
                    assertion: assertion,
                    passed: false,
                    message: "Could not read file: \(path)"
                )
            }
            let passed = content == expected
            return AssertionResult(
                assertion: assertion,
                passed: passed,
                message: passed
                    ? "File \(path) matches expected content"
                    : "File \(path) does not match expected content"
            )
        case .commandSucceeds(let command):
            let result = await runCommand(command, in: rootURL)
            return AssertionResult(
                assertion: assertion,
                passed: result.exitCode == 0,
                message: result.exitCode == 0
                    ? "Command succeeded: \(command.joined(separator: " "))"
                    : "Command failed with exit code \(result.exitCode): \(result.output)"
            )
        case .commandOutputContains(let command, let substring):
            let result = await runCommand(command, in: rootURL)
            let passed = result.output.contains(substring)
            return AssertionResult(
                assertion: assertion,
                passed: passed,
                message: passed
                    ? "Command output contains '\(substring)'"
                    : "Command output does not contain '\(substring)'"
            )
        }
    }

    /// Run a shell command in the workspace and capture its output.
    private func runCommand(_ command: [String], in directory: URL) async -> CommandResult {
        guard !command.isEmpty else {
            return CommandResult(exitCode: 1, output: "Empty command")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return CommandResult(exitCode: Int(process.terminationStatus), output: output)
        } catch {
            return CommandResult(exitCode: 1, output: "\(error)")
        }
    }
}

/// Marker error thrown when an eval run exceeds its timeout.
private struct EvalTimeoutError: Error {}

private struct CommandResult: Sendable {
    let exitCode: Int
    let output: String
}

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
