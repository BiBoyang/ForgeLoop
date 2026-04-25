import Foundation
import ForgeLoopAI

private let bashToolSchema = ToolArgsSchema(fields: [
    ToolArgField(name: "command", type: .string, required: true),
    ToolArgField(name: "timeoutMs", type: .numberOrString, required: false),
    ToolArgField(name: "mode", type: .string, required: false)
])

public struct BashTool: Tool {
    public let name = "bash"
    public let defaultTimeoutMs: Int
    private let manager: BackgroundTaskManager?

    public init(defaultTimeoutMs: Int = 15_000, manager: BackgroundTaskManager? = nil) {
        self.defaultTimeoutMs = defaultTimeoutMs
        self.manager = manager
    }

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        let validation = ToolArgsValidator.validate(arguments, schema: bashToolSchema)
        let args: ValidatedArgs
        switch validation {
        case .success(let validated):
            args = validated
        case .failure(let errors):
            return ToolArgsValidator.formatErrors(errors)
        }

        guard let command = args.string("command") else {
            return ToolResult.error(.invalidType, message: "Invalid type for command: expected string", hint: "path: $.command")
        }

        let mode = args.string("mode") ?? "foreground"
        guard mode == "foreground" || mode == "background" else {
            return ToolResult.error(.invalidType, message: "Invalid value for mode: expected 'foreground' or 'background'", hint: "path: $.mode")
        }

        // background mode
        if mode == "background" {
            guard let manager = manager else {
                return ToolResult.error(.notImplemented, message: "Background mode requires a BackgroundTaskManager")
            }
            let id = await manager.start(command: command, cwd: cwd)
            return ToolResult(output: "Started background task: \(id)", isError: false)
        }

        // foreground mode (existing behavior)
        var timeoutMs = args.int("timeoutMs") ?? defaultTimeoutMs
        guard timeoutMs > 0 else {
            return ToolResult.error(.invalidType, message: "timeoutMs must be greater than 0", hint: "path: $.timeoutMs")
        }

        let result = await ProcessRunner.run(
            command: command,
            cwd: cwd,
            timeoutMs: timeoutMs,
            cancellation: cancellation
        )

        if cancellation?.isCancelled == true {
            return ToolResult.error(.cancelled, message: "Command aborted")
        }

        if result.timedOut {
            return ToolResult.error(.timeout, message: "Command timed out after \(timeoutMs)ms")
        }

        var output = ""
        if !result.stdout.isEmpty {
            output += result.stdout
        }
        if !result.stderr.isEmpty {
            if !output.isEmpty {
                output += "\n"
            }
            output += "[stderr]\n" + result.stderr
        }

        let isError = result.exitCode != 0
        if output.isEmpty {
            output = isError ? "Exit code: \(result.exitCode)" : "(no output)"
        }

        return ToolResult(output: output, isError: isError, errorCode: isError ? .executionFailed : nil)
    }
}
