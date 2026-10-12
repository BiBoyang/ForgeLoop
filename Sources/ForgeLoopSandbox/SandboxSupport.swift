import Foundation

/// seatbelt 运行环境探测。
///
/// 无状态纯计算 + 一次文件存在性查询，按 AGENTS.md §5 用 `Sendable` enum 命名空间，不引入 actor。
public enum SandboxSupport {

    public enum SupportError: Error, Equatable, Sendable {
        /// 非 macOS 平台，seatbelt 不存在。
        case unsupportedPlatform
        /// macOS 但 /usr/bin/sandbox-exec 缺失或不可执行。
        case sandboxExecMissing(path: String)
    }

    /// 当前平台是否支持 seatbelt（编译期判定 + 运行期存在性检测）。
    public static var isSupported: Bool {
        #if os(macOS)
        return FileManager.default.isExecutableFile(atPath: SandboxTransform.sandboxExecPath)
        #else
        return false
        #endif
    }

    /// 校验支持性，不支持则抛出明确错误。
    /// - Parameter executableCheck: 存在性检测注入点（测试用）；默认查真实文件系统。
    public static func ensureSupported(
        executableCheck: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws {
        #if os(macOS)
        guard executableCheck(SandboxTransform.sandboxExecPath) else {
            throw SupportError.sandboxExecMissing(path: SandboxTransform.sandboxExecPath)
        }
        #else
        throw SupportError.unsupportedPlatform
        #endif
    }
}
