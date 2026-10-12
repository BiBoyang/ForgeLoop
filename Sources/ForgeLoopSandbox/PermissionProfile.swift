import Foundation

/// 数据化的沙箱权限策略，对齐 Codex `SandboxPolicy` 的两维度（文件系统 × 网络）。
///
/// 纯值类型：`Codable & Sendable`，供 UI/配置层序列化、跨并发域传递。
/// 渲染与包装见 `SeatbeltProfileRenderer` / `SandboxTransform`。
public struct PermissionProfile: Codable, Sendable, Equatable {
    /// 文件系统维度。
    public enum FileSystem: Codable, Sendable, Equatable {
        /// 全局只读（仅放行系统临时目录可写）。
        case readOnly
        /// 只读 + 指定可写根列表（subpath 语义，含其下全部子路径）。
        case workspaceWrite(writableRoots: [URL])
        /// 不限制文件系统。
        case fullAccess
    }

    /// 网络维度。
    public enum Network: Codable, Sendable, Equatable {
        /// 禁止网络（seatbelt 下表现为 DNS/连接 syscall EPERM）。
        case disabled
        /// 放行全部网络。
        case enabled
        // 预留形状（暂未启用，待 TASK-sandbox-approval 定稿）：
        // case proxyWhitelist(hosts: [String], allowLocalBinding: Bool)
    }

    public var fileSystem: FileSystem
    public var network: Network

    public init(fileSystem: FileSystem, network: Network) {
        self.fileSystem = fileSystem
        self.network = network
    }

    /// 常用预设：只读 + 断网（最严）。
    public static let readOnly = PermissionProfile(fileSystem: .readOnly, network: .disabled)
}
