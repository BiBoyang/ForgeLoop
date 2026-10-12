import Foundation
import ForgeLoopAI
import ForgeLoopSandbox

public struct ProcessResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var timedOut: Bool

    public init(stdout: String, stderr: String, exitCode: Int32, timedOut: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

public enum ProcessRunner {
    /// 最大输出限制：64KB（每路），超限截断
    public static let maxOutputBytes = 65_536

    /// - Parameters:
    ///   - profile: 可选沙箱策略。nil = 不包装（默认，保持既有调用方行为）；
    ///     非 nil 时经 `SandboxTransform` 判定——需要沙箱则包装为
    ///     `/usr/bin/sandbox-exec -p <sbpl> ...`，`fullAccess + network enabled` 原样透传。
    public static func run(
        command: String,
        args: [String]? = nil,
        cwd: String,
        timeoutMs: Int? = nil,
        profile: PermissionProfile? = nil,
        cancellation: CancellationHandle?
    ) async -> ProcessResult {
        let process = Process()
        // 先决定"未经沙箱"的 exec 形态：有 args 直接 exec，无 args 走 /bin/sh -c（完整 shell 能力）
        let executable: String
        let arguments: [String]
        if let args = args {
            executable = command
            arguments = args
        } else {
            executable = "/bin/sh"
            arguments = ["-c", command]
        }
        // 沙箱包装复杂度沉在这里，调用方只传 profile
        if let profile = profile {
            let wrapped = SandboxTransform.wrap(command: executable, arguments: arguments, profile: profile)
            process.executableURL = URL(fileURLWithPath: wrapped[0])
            process.arguments = Array(wrapped.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }
        if !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        // 注入非交互环境：禁用分页器，避免命令因交互式行为卡住
        var env = ProcessInfo.processInfo.environment
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        env["MANPAGER"] = "cat"
        env["SYSTEMD_PAGER"] = "cat"
        process.environment = env

        // 将 stdin 指向 /dev/null，防止非交互命令等待输入挂住
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 设置取消回调
        if let cancellation = cancellation {
            cancellation.onCancel { _ in
                if process.isRunning {
                    process.terminate()
                }
            }
        }

        do {
            try process.run()
        } catch {
            return ProcessResult(
                stdout: "",
                stderr: "Failed to start process: \(error.localizedDescription)",
                exitCode: -1
            )
        }

        // If the handle was already cancelled before we got here, terminate immediately.
        if cancellation?.isCancelled == true {
            process.terminate()
        }

        return await withCheckedContinuation { continuation in
            // 超时任务：到时间后 kill 进程（nil 表示无超时）
            let timeoutTask: Task<Void, Never>?
            if let timeoutMs = timeoutMs, timeoutMs > 0 {
                let clampedTimeoutMs = max(timeoutMs, 1)
                timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(clampedTimeoutMs) * 1_000_000)
                    if process.isRunning {
                        process.terminate()
                    }
                }
            } else {
                timeoutTask = nil
            }

            // 进程结束回调
            process.terminationHandler = { p in
                timeoutTask?.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdoutText = String(data: stdoutData.prefix(maxOutputBytes), encoding: .utf8) ?? ""
                let stderrText = String(data: stderrData.prefix(maxOutputBytes), encoding: .utf8) ?? ""

                let isTimedOut = p.terminationReason == .uncaughtSignal && timeoutTask != nil
                continuation.resume(returning: ProcessResult(
                    stdout: stdoutText,
                    stderr: stderrText,
                    exitCode: p.terminationStatus,
                    timedOut: isTimedOut
                ))
            }
        }
    }
}
