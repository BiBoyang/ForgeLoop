import Foundation
import ForgeLoopAI
import ForgeLoopSandbox

let bashToolSchema = ToolArgsSchema(fields: [
    ToolArgField(name: "command", type: .string, required: true),
    ToolArgField(name: "args", type: .stringArray, required: false),
    ToolArgField(name: "timeoutMs", type: .numberOrString, required: false),
    ToolArgField(name: "mode", type: .string, required: false)
])

/// 沙箱升级审批回调：入参为 (命令, 拒绝原因)，返回 true = 批准以非沙箱方式重跑一次。
/// `@Sendable` 闭包，由调用方（CLI/App）注入；nil = 不审批（等价 policy=never）。
public typealias SandboxEscalationHandler = @Sendable (String, String) async -> Bool

/// 无 `args` 时 command 经 `/bin/sh -c` 执行（完整 shell 能力：管道/重定向/复合命令）；
/// 安全边界由 OS 沙箱（seatbelt）承担，profile 从注入点获取。
/// 沙箱拒绝（EPERM 启发式）且 policy=onFailure 时，经 escalationHandler 请求升级：
/// 批准 → 非沙箱重跑一次（仅一次，不循环）；拒绝/handler 缺失 → 原失败结果回灌并附提示。
public struct BashTool: Tool {
    public let name = "bash"

    public var definition: ToolDefinition {
        ToolDefinition.make(
            name: name,
            description: "Run a shell command in the working directory. Without `args`, `command` runs via /bin/sh -c (pipes and redirections work); with `args`, the executable is run directly. Foreground mode waits for completion and returns output, bounded by `timeoutMs` (milliseconds). mode=\"background\" starts a background task instead (`args` not allowed); poll it with bg_status. Commands may run sandboxed and can be denied.",
            argsSchema: bashToolSchema
        )
    }
    public let defaultTimeoutMs: Int
    private let manager: BackgroundTaskManager?
    /// 沙箱策略。nil = 不包装（默认，保持既有调用方行为）。
    private let profile: PermissionProfile?
    /// 升级审批策略，默认 onFailure。
    private let policy: ApprovalPolicy
    /// 升级审批回调；nil = 不审批。
    private let escalationHandler: SandboxEscalationHandler?

    public init(defaultTimeoutMs: Int = 15_000,
                manager: BackgroundTaskManager? = nil,
                profile: PermissionProfile? = nil,
                policy: ApprovalPolicy = .default,
                escalationHandler: SandboxEscalationHandler? = nil) {
        self.defaultTimeoutMs = defaultTimeoutMs
        self.manager = manager
        self.profile = profile
        self.policy = policy
        self.escalationHandler = escalationHandler
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

        var result = await ProcessRunner.run(
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

        // 沙箱拒绝升级链路：命中启发式 → 按 policy 请求审批 → 批准后非沙箱重跑一次（仅一次）
        var denialNote: String?
        if shouldOfferEscalation(result: result) {
            let reason = Self.denialReason(from: result)
            if policy == .onFailure, let escalationHandler {
                let approved = await escalationHandler(command, reason)
                if cancellation?.isCancelled == true {
                    return ToolResult.error(.cancelled, message: "Command aborted")
                }
                if approved {
                    // 非沙箱重跑：profile=nil 等价 fullAccess + network enabled 透传；
                    // 直接调 ProcessRunner（不递归回 BashTool），保证仅重跑一次
                    result = await ProcessRunner.run(
                        command: command,
                        args: commandArgs,
                        cwd: cwd,
                        timeoutMs: timeoutMs,
                        profile: nil,
                        cancellation: cancellation
                    )
                    if cancellation?.isCancelled == true {
                        return ToolResult.error(.cancelled, message: "Command aborted")
                    }
                } else {
                    denialNote = "[sandbox] 沙箱拒绝且用户未批准升级；可按 fullAccess profile 重跑或调整可写根"
                }
            } else {
                denialNote = "[sandbox] 沙箱拒绝（\(reason)）；当前无可用的升级审批通道"
            }
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
        if let denialNote {
            output += "\n" + denialNote
        }

        return ToolResult(output: output, isError: isError, errorCode: isError ? .executionFailed : nil)
    }

    /// 是否应触发升级询问：仅当本次确实经沙箱执行、未超时、且命中 EPERM 启发式。
    private func shouldOfferEscalation(result: ProcessResult) -> Bool {
        guard let profile, SandboxTransform.requiresSandbox(profile) else { return false }
        guard !result.timedOut else { return false }
        return SandboxDenialHeuristic.isLikelySandboxDenial(exitCode: result.exitCode, stderr: result.stderr)
    }

    /// 从结果提炼一行拒绝原因（取 stderr 首行，供审批 UI 展示）。
    private static func denialReason(from result: ProcessResult) -> String {
        let firstLine = result.stderr.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "exit \(result.exitCode) with EPERM" : firstLine
    }
}
