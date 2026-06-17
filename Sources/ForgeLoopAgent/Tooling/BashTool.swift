import Foundation
import ForgeLoopAI

private let bashToolSchema = ToolArgsSchema(fields: [
    ToolArgField(name: "command", type: .string, required: true),
    ToolArgField(name: "args", type: .stringArray, required: false),
    ToolArgField(name: "timeoutMs", type: .numberOrString, required: false),
    ToolArgField(name: "mode", type: .string, required: false)
])

/// 对仍走 shell 的 command 做最小审计，阻断常见命令注入向量。
private enum ShellCommandAuditor {
    /// 禁止出现的 shell 元字符。简单命令（含空格、引号、减号、斜杠）仍可通过。
    static let forbiddenCharacters = CharacterSet(charactersIn: ";`$|&<>{}()\\\n\r")

    static func validate(_ command: String) -> ToolResult? {
        if command.rangeOfCharacter(from: forbiddenCharacters) != nil {
            return ToolResult.error(
                .executionFailed,
                message: "Command contains forbidden shell metacharacters. Use simple commands or provide an executable and args.",
                hint: "path: $.command"
            )
        }
        return nil
    }
}

public struct BashTool: Tool {
    public let name = "bash"
    public let defaultTimeoutMs: Int
    private let manager: BackgroundTaskManager?

    public init(defaultTimeoutMs: Int = 15_000, manager: BackgroundTaskManager? = nil) {
        self.defaultTimeoutMs = defaultTimeoutMs
        self.manager = manager
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
            if let auditError = ShellCommandAuditor.validate(command) {
                return auditError
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

        // 未使用 args 时，必须经过 shell 审计。
        if commandArgs == nil, let auditError = ShellCommandAuditor.validate(command) {
            return auditError
        }

        let result = await ProcessRunner.run(
            command: command,
            args: commandArgs,
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
