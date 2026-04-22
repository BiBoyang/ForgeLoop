import Foundation
import ForgeLoopAI

public enum ToolErrorCode: String, Sendable {
    case missingArgument
    case outsideCwd
    case pathNotFound
    case targetIsDirectory
    case targetNotDirectory
    case textNotFound
    case executionFailed
    case sizeExceeded
    case timeout
    case unknownTool
    case cancelled
    case notImplemented
}

public struct ToolResult: Sendable {
    public var output: String
    public var isError: Bool
    public var errorCode: ToolErrorCode?

    public init(output: String, isError: Bool = false, errorCode: ToolErrorCode? = nil) {
        self.output = output
        self.isError = isError
        self.errorCode = errorCode
    }

    /// 统一错误输出格式：`[<code>] message (hint)`
    public static func error(
        _ code: ToolErrorCode,
        message: String,
        hint: String? = nil
    ) -> ToolResult {
        var output = "[\(code.rawValue)] \(message)"
        if let hint = hint {
            output += " (hint: \(hint))"
        }
        return ToolResult(output: output, isError: true, errorCode: code)
    }
}

public protocol Tool: Sendable {
    var name: String { get }
    func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult
}

public final class ToolExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [String: any Tool] = [:]

    public init() {}

    public func register(_ tool: any Tool) {
        lock.withLock {
            tools[tool.name] = tool
        }
    }

    public func execute(
        name: String,
        arguments: String,
        cwd: String,
        cancellation: CancellationHandle?
    ) async -> ToolResult {
        let tool = lock.withLock { tools[name] }
        guard let tool else {
            return ToolResult.error(
                .unknownTool,
                message: "Unknown tool: \(name)",
                hint: "Available: \(lock.withLock { Array(tools.keys).sorted() }.joined(separator: ", "))"
            )
        }
        return await tool.execute(arguments: arguments, cwd: cwd, cancellation: cancellation)
    }

    public var availableToolNames: [String] {
        lock.withLock { Array(tools.keys).sorted() }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
