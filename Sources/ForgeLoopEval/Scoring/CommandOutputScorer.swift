import Foundation

/// Scores command assertions: `commandSucceeds` and `commandOutputContains`.
///
/// Commands are executed in the workspace root directory using `/usr/bin/env`
/// as the executable.
public struct CommandOutputScorer: EvalScorer {
    private let textMatcher = TextMatchScorer()

    public init() {}

    public func canScore(_ assertion: EvalAssertion) -> Bool {
        switch assertion {
        case .commandSucceeds, .commandOutputContains:
            return true
        default:
            return false
        }
    }

    public func score(assertion: EvalAssertion, workspace: Workspace) async -> AssertionResult {
        let rootURL = workspace.rootURL

        switch assertion {
        case .commandSucceeds(let command):
            let result = await runCommand(command, in: rootURL)
            let passed = result.exitCode == 0
            return AssertionResult(
                assertion: assertion,
                passed: passed,
                message: passed
                    ? "Command succeeded: \(command.joined(separator: " "))"
                    : "Command failed with exit code \(result.exitCode): \(result.output)"
            )
        case .commandOutputContains(let command, let substring):
            let result = await runCommand(command, in: rootURL)
            let passed = textMatcher.contains(result.output, substring: substring)
            return AssertionResult(
                assertion: assertion,
                passed: passed,
                message: passed
                    ? "Command output contains '\(substring)'"
                    : "Command output does not contain '\(substring)'"
            )
        default:
            return AssertionResult(
                assertion: assertion,
                passed: false,
                message: "Unsupported assertion"
            )
        }
    }
}

/// The result of a single command invocation.
private struct CommandRunResult: Sendable {
    let exitCode: Int
    let output: String
}

/// Holds a running `Process` so that cancellation can terminate it.
///
/// This actor isolates the process reference across the `@Sendable`
/// cancellation handler and the continuation-based run path.
private actor ProcessHolder {
    private var process: Process?

    func set(_ process: Process?) {
        self.process = process
    }

    func terminate() {
        process?.terminate()
    }
}

/// Run a shell command in `directory` and capture its combined stdout/stderr.
///
/// TODO: This implementation uses `Process.terminationHandler` and
/// `withCheckedContinuation` to bridge to `async/await`. It is cancellation
/// aware via `ProcessHolder.terminate()`, but does not yet propagate
/// `Task.isCancelled` checks while the process is running.
private func runCommand(_ command: [String], in directory: URL) async -> CommandRunResult {
    guard !command.isEmpty else {
        return CommandRunResult(exitCode: 1, output: "Empty command")
    }

    let holder = ProcessHolder()

    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            Task {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = command
                process.currentDirectoryURL = directory

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                await holder.set(process)

                process.terminationHandler = { _ in
                    Task {
                        await holder.set(nil)
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(
                        returning: CommandRunResult(
                            exitCode: Int(process.terminationStatus),
                            output: output
                        )
                    )
                }

                do {
                    try process.run()
                } catch {
                    Task {
                        await holder.set(nil)
                    }
                    continuation.resume(
                        returning: CommandRunResult(exitCode: 1, output: "\(error)")
                    )
                }
            }
        }
    } onCancel: {
        Task {
            await holder.terminate()
        }
    }
}
