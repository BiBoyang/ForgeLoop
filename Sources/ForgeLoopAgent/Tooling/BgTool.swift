import Foundation
import ForgeLoopAI

public struct BgTool: Tool {
    public let name = "bg"
    private let manager: BackgroundTaskManager
    private let onComplete: (@Sendable (BackgroundTaskRecord) async -> Void)?

    public init(manager: BackgroundTaskManager, onComplete: (@Sendable (BackgroundTaskRecord) async -> Void)? = nil) {
        self.manager = manager
        self.onComplete = onComplete
    }

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        guard let args = parseArgs(arguments), let command = args["command"] else {
            return ToolResult.error(.missingArgument, message: "Missing required argument: command")
        }

        if let handler = onComplete {
            await manager.setCompletionHandler(handler)
        }

        let id = await manager.start(command: command, cwd: cwd)
        return ToolResult(output: "Started background task: \(id)", isError: false)
    }
}
