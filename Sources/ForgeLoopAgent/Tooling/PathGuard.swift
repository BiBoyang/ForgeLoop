import Foundation

public enum PathError: Error, Sendable {
    case outsideCwd
    case targetIsDirectory
    case pathNotFound(String)
}

public struct PathGuard: Sendable {
    public let cwd: URL

    public init(cwd: String) {
        self.cwd = URL(fileURLWithPath: cwd).standardizedFileURL
    }

    /// 验证并解析路径，返回标准化后的绝对路径 URL。
    /// 如果路径越界（不在 cwd 下）则抛出 .outsideCwd。
    public func resolve(_ path: String) throws -> URL {
        let absolute = URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL
        guard absolute.path.hasPrefix(cwd.path + "/") || absolute.path == cwd.path else {
            throw PathError.outsideCwd
        }
        return absolute
    }

    /// 验证路径是文件（不是目录）。
    public func verifyIsFile(_ url: URL) throws {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !exists {
            throw PathError.pathNotFound(url.path)
        }
        if isDir.boolValue {
            throw PathError.targetIsDirectory
        }
    }
}
