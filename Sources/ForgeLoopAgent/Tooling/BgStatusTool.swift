import Foundation
import ForgeLoopAI

public struct BgStatusTool: Tool {
    public let name = "bg_status"
    private let manager: BackgroundTaskManager

    public init(manager: BackgroundTaskManager) {
        self.manager = manager
    }

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        let args = parseArgs(arguments)
        let id = args?["id"]

        let tasks = await manager.status(id: id)
        if tasks.isEmpty {
            if let id = id {
                return ToolResult(output: "No task found with id: \(id)", isError: false)
            }
            return ToolResult(output: "(no background tasks)", isError: false)
        }

        let lines = tasks.map { task in
            let duration: String
            if let finished = task.finishedAt {
                duration = "finished in \(String(format: "%.1f", finished.timeIntervalSince(task.startedAt)))s"
            } else {
                duration = "running for \(String(format: "%.1f", Date().timeIntervalSince(task.startedAt)))s"
            }
            let source = task.cancelledBy.map { " [by: \($0)]" } ?? ""
            return "\(task.id): \(task.status.rawValue)\(source) | \(task.command) | \(duration)"
        }

        return ToolResult(output: lines.joined(separator: "\n"), isError: false)
    }
}
