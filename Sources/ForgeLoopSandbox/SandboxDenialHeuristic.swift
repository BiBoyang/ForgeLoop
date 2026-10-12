import Foundation

/// 沙箱拒绝启发式判定：纯函数 (exitCode, stderr) → Bool。
///
/// 锚点收紧（notes/sandbox-spike-report.md §2 实测）：
/// - 非零退出 + stderr 含 `Operation not permitted`（EPERM 的 strerror，跨工具稳定）
/// - 网络拒绝（如 curl exit 6 `Could not resolve host`，DNS 先撞墙）**v1 不触发升级**：
///   网络放行的升级语义与 fs 不同（需要改 profile 而非整体放行），留给后续版本。
public enum SandboxDenialHeuristic {
    /// EPERM 的 strerror 文本，沙箱拒绝的稳定锚点。
    public static let epermMarker = "Operation not permitted"

    public static func isLikelySandboxDenial(exitCode: Int32, stderr: String) -> Bool {
        guard exitCode != 0 else { return false }
        return stderr.contains(epermMarker)
    }
}
