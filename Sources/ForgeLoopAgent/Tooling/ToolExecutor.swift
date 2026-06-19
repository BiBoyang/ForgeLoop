import Foundation
import ForgeLoopAI
import ForgeLoopDiagnostics

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

    // HB-001: 参数校验错误 taxonomy
    case invalidJson
    case missingRequired
    case invalidType
    case unknownField
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
    private let diagnostics: Diagnostics

    /// Safety invariant: `diagnostics` is a value type (`Sendable`), so sharing it
    /// across concurrency boundaries is safe despite `@unchecked Sendable`.
    public init(diagnostics: Diagnostics = Diagnostics()) {
        self.diagnostics = diagnostics
    }

    public func register(_ tool: any Tool) {
        lock.withLock {
            tools[tool.name] = tool
        }
        Task {
            await diagnostics.log.log(
                level: .debug,
                message: "tool.registered",
                attributes: [
                    "tool": .string(tool.name),
                    "available_tools": .string(availableToolNames.joined(separator: ","))
                ]
            )
        }
    }

    public func execute(
        name: String,
        arguments: String,
        cwd: String,
        cancellation: CancellationHandle?,
        traceContext: TraceContext? = nil
    ) async -> ToolResult {
        let tool = lock.withLock { tools[name] }
        let available = lock.withLock { Array(tools.keys).sorted() }

        let span = await diagnostics.trace.startSpan(
            name: "tool.execute",
            parent: traceContext,
            layer: "Agent",
            operation: "execute",
            attributes: [
                "tool": .string(name),
                "cwd": .string(cwd)
            ]
        )

        guard let tool = tool else {
            await diagnostics.trace.endSpan(
                span,
                attributes: [:],
                error: TraceError(type: "unknownTool", message: "Unknown tool: \(name)")
            )
            return ToolResult.error(
                .unknownTool,
                message: "Unknown tool: \(name)",
                hint: "Available: \(available.joined(separator: ", "))"
            )
        }

        let result = await TraceContextStorage.$current.withValue(span) {
            await tool.execute(arguments: arguments, cwd: cwd, cancellation: cancellation)
        }

        let toolError: TraceError?
        if result.isError, let code = result.errorCode {
            toolError = TraceError(type: code.rawValue, message: result.output)
        } else {
            toolError = nil
        }
        await diagnostics.trace.endSpan(span, attributes: [:], error: toolError)
        return result
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
