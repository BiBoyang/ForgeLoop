import Foundation
import ForgeLoopAI

public struct ReadTool: Tool {
    public let name = "read"

    public init() {}

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        guard let args = parseArgs(arguments), let path = args["path"] else {
            return ToolResult.error(.missingArgument, message: "Missing required argument: path")
        }

        let guard_ = PathGuard(cwd: cwd)
        do {
            let url = try guard_.resolve(path)
            try guard_.verifyIsFile(url)
            let content = try String(contentsOf: url, encoding: .utf8)
            return ToolResult(output: content, isError: false)
        } catch PathError.outsideCwd {
            return ToolResult.error(.outsideCwd, message: "Path '\(path)' is outside the working directory")
        } catch PathError.targetIsDirectory {
            return ToolResult.error(.targetIsDirectory, message: "Path '\(path)' is a directory, not a file")
        } catch PathError.pathNotFound {
            return ToolResult.error(.pathNotFound, message: "File not found: \(path)")
        } catch {
            return ToolResult.error(.executionFailed, message: "Failed to read '\(path)': \(error.localizedDescription)")
        }
    }
}

public struct WriteTool: Tool {
    public let name = "write"

    public init() {}

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        guard let args = parseArgs(arguments),
              let path = args["path"],
              let content = args["content"] else {
            return ToolResult.error(.missingArgument, message: "Missing required arguments: path, content")
        }

        let guard_ = PathGuard(cwd: cwd)
        do {
            let url = try guard_.resolve(path)

            // 拒绝写入已存在的目录
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return ToolResult.error(.targetIsDirectory, message: "Path '\(path)' is a directory, cannot overwrite")
                }
            }

            // 确保父目录存在
            let parentDir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolResult(output: "Wrote \(content.utf8.count) bytes to \(path)", isError: false)
        } catch PathError.outsideCwd {
            return ToolResult.error(.outsideCwd, message: "Path '\(path)' is outside the working directory")
        } catch {
            return ToolResult.error(.executionFailed, message: "Failed to write '\(path)': \(error.localizedDescription)")
        }
    }
}

/// 简单解析 JSON 参数字符串为 [String: String]。
/// 仅支持顶层字符串键值对，不处理嵌套对象/数组。
func parseArgs(_ json: String) -> [String: String]? {
    guard let data = json.data(using: .utf8) else { return nil }
    guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

    var result: [String: String] = [:]
    for (key, value) in dict {
        if let str = value as? String {
            result[key] = str
        } else if let num = value as? NSNumber {
            result[key] = num.stringValue
        } else if let bool = value as? Bool {
            result[key] = bool ? "true" : "false"
        }
    }
    return result
}
