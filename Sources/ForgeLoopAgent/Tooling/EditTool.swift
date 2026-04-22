import Foundation
import ForgeLoopAI

public struct EditTool: Tool {
    public let name = "edit"
    public let maxFileSize: Int

    public init(maxFileSize: Int = 1_048_576) {
        self.maxFileSize = maxFileSize
    }

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        guard let args = parseArgs(arguments),
              let path = args["path"],
              let oldText = args["oldText"],
              let newText = args["newText"] else {
            return ToolResult.error(.missingArgument, message: "Missing required arguments: path, oldText, newText")
        }

        let guard_ = PathGuard(cwd: cwd)
        do {
            let url = try guard_.resolve(path)

            // Verify file exists and is a regular file
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists else {
                return ToolResult.error(.pathNotFound, message: "File not found: \(path)")
            }
            guard !isDir.boolValue else {
                return ToolResult.error(.targetIsDirectory, message: "Path '\(path)' is a directory, not a file")
            }

            // Check file size
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[FileAttributeKey.size] as? Int, fileSize > maxFileSize {
                return ToolResult.error(.sizeExceeded, message: "File exceeds maximum size limit (\(maxFileSize) bytes)")
            }

            var content = try String(contentsOf: url, encoding: .utf8)

            // Replace first occurrence
            guard let range = content.range(of: oldText) else {
                return ToolResult.error(.textNotFound, message: "Could not find the text to replace in \(path)")
            }

            content.replaceSubrange(range, with: newText)
            try content.write(to: url, atomically: true, encoding: .utf8)

            return ToolResult(output: "Edited \(path) (1 replacement)", isError: false)
        } catch PathError.outsideCwd {
            return ToolResult.error(.outsideCwd, message: "Path '\(path)' is outside the working directory")
        } catch {
            return ToolResult.error(.executionFailed, message: "Failed to edit '\(path)': \(error.localizedDescription)")
        }
    }
}
