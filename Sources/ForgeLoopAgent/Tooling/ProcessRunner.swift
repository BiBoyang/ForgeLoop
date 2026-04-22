import Foundation
import ForgeLoopAI

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

    public static func run(
        command: String,
        cwd: String,
        timeoutMs: Int? = nil,
        cancellation: CancellationHandle?
    ) async -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        if !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

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
