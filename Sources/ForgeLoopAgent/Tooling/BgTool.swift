import Foundation
import ForgeLoopAI

private let bgToolSchema = ToolArgsSchema(fields: [
    ToolArgField(name: "command", type: .string, required: true)
])

public struct BgTool: Tool {
    public let name = "bg"
    private let manager: BackgroundTaskManager
    private let onComplete: (@Sendable (BackgroundTaskRecord) async -> Void)?

    public init(manager: BackgroundTaskManager, onComplete: (@Sendable (BackgroundTaskRecord) async -> Void)? = nil) {
        self.manager = manager
        self.onComplete = onComplete
    }

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        let validation = ToolArgsValidator.validate(arguments, schema: bgToolSchema)
        let args: ValidatedArgs
        switch validation {
        case .success(let validated):
            args = validated
        case .failure(let errors):
            return ToolArgsValidator.formatErrors(errors)
        }

        guard let command = args.string("command") else {
            return ToolResult.error(.invalidType, message: "Invalid type for command: expected string", hint: "path: $.command")
        }

        if let handler = onComplete {
            await manager.setCompletionHandler(handler)
        }

        let id = await manager.start(command: command, cwd: cwd)
        return ToolResult(output: "Started background task: \(id)", isError: false)
    }
}
