import Foundation
import ForgeLoopAI

public struct ListTool: Tool {
    public let name = "ls"

    public init() {}

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        let args = parseArgs(arguments)
        let path = args?["path"] ?? "."

        let guard_ = PathGuard(cwd: cwd)
        do {
            let url = try guard_.resolve(path)

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists else {
                return ToolResult.error(.pathNotFound, message: "Path not found: \(path)")
            }

            let targetURL: URL
            if !isDir.boolValue {
                // If path is a file, list its parent directory
                targetURL = url.deletingLastPathComponent()
            } else {
                targetURL = url
            }

            let contents = try FileManager.default.contentsOfDirectory(at: targetURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            let sorted = contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            var lines: [String] = []
            for item in sorted {
                let itemIsDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let prefix = itemIsDir ? "d" : "-"
                lines.append("\(prefix) \(item.lastPathComponent)")
            }

            if lines.isEmpty {
                return ToolResult(output: "(empty directory)", isError: false)
            }

            return ToolResult(output: lines.joined(separator: "\n"), isError: false)
        } catch PathError.outsideCwd {
            return ToolResult.error(.outsideCwd, message: "Path '\(path)' is outside the working directory")
        } catch {
            return ToolResult.error(.executionFailed, message: "Failed to list '\(path)': \(error.localizedDescription)")
        }
    }
}
