import Foundation
import ForgeLoopAI
import ForgeLoopSandbox

private let bashToolSchema = ToolArgsSchema(fields: [
    ToolArgField(name: "command", type: .string, required: true),
    ToolArgField(name: "args", type: .stringArray, required: false),
    ToolArgField(name: "timeoutMs", type: .numberOrString, required: false),
    ToolArgField(name: "mode", type: .string, required: false)
])

/// 无 `args` 时 command 经 `/bin/sh -c` 执行（完整 shell 能力：管道/重定向/复合命令）；
/// 安全边界由 OS 沙箱（seatbelt）承担，profile 从注入点获取。
public struct BashTool: Tool {
    public let name = "bash"
    public let defaultTimeoutMs: Int
    private let manager: BackgroundTaskManager?
    /// 沙箱策略。nil = 不包装（默认，保持既有调用方行为）。
    private let profile: PermissionProfile?

    public init(defaultTimeoutMs: Int = 15_000,
                manager: BackgroundTaskManager? = nil,
                profile: PermissionProfile? = nil) {
        self.defaultTimeoutMs = defaultTimeoutMs
        self.manager = manager
        self.profile = profile
    }

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        if cancellation?.isCancelled == true {
            return ToolResult.error(.cancelled, message: "Command aborted")
        }

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

        let commandArgs = args.stringArray("args")
        let mode = args.string("mode") ?? "foreground"
        guard mode == "foreground" || mode == "background" else {
            return ToolResult.error(.invalidType, message: "Invalid value for mode: expected 'foreground' or 'background'", hint: "path: $.mode")
        }

        // background mode
        if mode == "background" {
            guard commandArgs == nil else {
                return ToolResult.error(.invalidType, message: "args is not supported in background mode", hint: "path: $.args")
            }
            guard let manager = manager else {
                return ToolResult.error(.notImplemented, message: "Background mode requires a BackgroundTaskManager")
            }
            do {
                let id = try await manager.start(command: command, cwd: cwd)
                return ToolResult(output: "Started background task: \(id)", isError: false)
            } catch BackgroundTaskStartError.maxConcurrentReached(let limit) {
                return ToolResult.error(.executionFailed, message: "Maximum concurrent background tasks reached (\(limit))")
            } catch {
                return ToolResult.error(.executionFailed, message: "Failed to start background task: \(error.localizedDescription)")
            }
        }

        // foreground mode (existing behavior)
        let timeoutMs = args.int("timeoutMs") ?? defaultTimeoutMs
        guard timeoutMs > 0 else {
            return ToolResult.error(.invalidType, message: "timeoutMs must be greater than 0", hint: "path: $.timeoutMs")
        }

        let result = await ProcessRunner.run(
            command: command,
            args: commandArgs,
            cwd: cwd,
            timeoutMs: timeoutMs,
            profile: profile,
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
