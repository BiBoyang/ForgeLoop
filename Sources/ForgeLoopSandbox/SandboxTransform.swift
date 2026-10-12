import Foundation

/// 纯函数式命令包装：(command, args, PermissionProfile) → 包装后 argv。
///
/// - `fullAccess` 文件系统 + `enabled` 网络 = 无任何限制，原样透传，不包 sandbox-exec。
/// - 其余组合包装为 `[/usr/bin/sandbox-exec, -p, <sbpl>, command, args...]`。
/// - sandbox-exec 绝对路径硬编码（防 PATH 注入，对齐 Codex `MACOS_PATH_TO_SEATBELT_EXECUTABLE`）。
///
/// 纯函数，零 IO；profile 文本由 `SeatbeltProfileRenderer` 生成。
public enum SandboxTransform {

    /// seatbelt 可执行文件绝对路径。只信 /usr/bin，不走 PATH 解析。
    public static let sandboxExecPath = "/usr/bin/sandbox-exec"

    /// 包装命令。返回数组首元素为可执行文件路径，其余为参数。
    public static func wrap(command: String,
                            arguments: [String],
                            profile: PermissionProfile) -> [String] {
        if profile.fileSystem == .fullAccess, profile.network == .enabled {
            return [command] + arguments
        }
        let sbpl = SeatbeltProfileRenderer.render(profile)
        return [sandboxExecPath, "-p", sbpl, command] + arguments
    }

    /// 判断该 profile 是否需要 sandbox-exec 包装。
    public static func requiresSandbox(_ profile: PermissionProfile) -> Bool {
        !(profile.fileSystem == .fullAccess && profile.network == .enabled)
    }
}
