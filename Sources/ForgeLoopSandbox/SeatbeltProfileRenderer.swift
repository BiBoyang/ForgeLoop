import Foundation

/// 纯函数式 seatbelt profile 渲染器：PermissionProfile → `.sbpl` 文本。
///
/// - `(deny default)` 起手（fullAccess 除外，其语义为 `(allow default)`）。
/// - base 骨架采用上游 TASK-sandbox-spike 报告 §3 实测模板。
/// - writableRoots 必须经 `realpath(3)` canonicalize：`/var` 是 firmlink，
///   seatbelt 按真实路径匹配 subpath，`URL.resolvingSymlinksInPath` 实测无效
///   （上游报告 §4 踩坑 1）。realpath 要求路径存在；不存在时回退原路径并保留放行条目
///   （与 Codex 拒绝不存在可写根的策略不同，本模块保持纯函数、不抛错，由调用方决定）。
public enum SeatbeltProfileRenderer {

    /// 渲染完整 `.sbpl` 文本。纯函数，无副作用。
    public static func render(_ profile: PermissionProfile) -> String {
        var lines: [String] = ["(version 1)"]

        switch profile.fileSystem {
        case .fullAccess:
            lines.append("(allow default)")
            if profile.network == .disabled {
                lines.append("(deny network*)")
            }
            return lines.joined(separator: "\n") + "\n"

        case .readOnly, .workspaceWrite:
            lines.append("(deny default)")
            lines.append(contentsOf: baseSkeleton)
        }

        if case .workspaceWrite(let writableRoots) = profile.fileSystem {
            for root in writableRoots {
                let canonical = canonicalize(root.path)
                lines.append("(allow file-read* file-write* (subpath \"\(escape(canonical))\"))")
            }
        }

        if profile.network == .enabled {
            lines.append("(allow network*)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// base 骨架：进程/exec/信号/sysctl/mach/tty 基础放行 + 全局只读 + 系统临时目录可写 + /dev/null。
    /// 与 notes/sandbox-spike-report.md §3 模板逐项一致。
    private static let baseSkeleton: [String] = [
        "(allow process-exec)",
        "(allow process-fork)",
        "(allow signal (target same-sandbox))",
        "(allow process-info* (target same-sandbox))",
        "(allow sysctl-read)",
        "(allow mach-lookup)",
        "(allow ipc-posix-shm-read-data ipc-posix-shm-write-data)",
        "(allow pseudo-tty)",
        "(allow file-read*)",
        "(allow file-read* file-test-existence file-write*",
        "    (subpath \"/tmp\")",
        "    (subpath \"/private/tmp\")",
        "    (subpath \"/var/tmp\")",
        "    (subpath \"/private/var/tmp\"))",
        "(allow file-write-data",
        "  (require-all",
        "    (path \"/dev/null\")",
        "    (vnode-type CHARACTER-DEVICE)))",
    ]

    /// realpath(3) canonicalize。路径不存在时回退为原路径。
    public static func canonicalize(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        guard realpath(path, &buf) != nil else { return path }
        return String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// sbpl 字符串字面量转义：反斜杠与双引号。
    public static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
