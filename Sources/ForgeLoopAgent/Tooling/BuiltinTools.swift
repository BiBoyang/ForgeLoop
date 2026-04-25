import Foundation
import ForgeLoopAI

private let readToolSchema = ToolArgsSchema(fields: [
    ToolArgField(name: "path", type: .string, required: true)
])

public struct ReadTool: Tool {
    public let name = "read"

    public init() {}

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        let validation = ToolArgsValidator.validate(arguments, schema: readToolSchema)
        let args: ValidatedArgs
        switch validation {
        case .success(let validated):
            args = validated
        case .failure(let errors):
            return ToolArgsValidator.formatErrors(errors)
        }

        guard let path = args.string("path") else {
            return ToolResult.error(.invalidType, message: "Invalid type for path: expected string", hint: "path: $.path")
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

private let writeToolSchema = ToolArgsSchema(fields: [
    ToolArgField(name: "path", type: .string, required: true),
    ToolArgField(name: "content", type: .string, required: true)
])

public struct WriteTool: Tool {
    public let name = "write"

    public init() {}

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        let validation = ToolArgsValidator.validate(arguments, schema: writeToolSchema)
        let args: ValidatedArgs
        switch validation {
        case .success(let validated):
            args = validated
        case .failure(let errors):
            return ToolArgsValidator.formatErrors(errors)
        }

        guard let path = args.string("path") else {
            return ToolResult.error(.invalidType, message: "Invalid type for path: expected string", hint: "path: $.path")
        }
        guard let content = args.string("content") else {
            return ToolResult.error(.invalidType, message: "Invalid type for content: expected string", hint: "path: $.content")
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
