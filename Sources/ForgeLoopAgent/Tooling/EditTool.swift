import Foundation
import ForgeLoopAI

public struct EditTool: Tool {
    public let name = "edit"
    public let maxFileSize: Int
    public let maxDiffPreviewChars: Int

    public init(maxFileSize: Int = 1_048_576, maxDiffPreviewChars: Int = 200) {
        self.maxFileSize = maxFileSize
        self.maxDiffPreviewChars = maxDiffPreviewChars
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

            let summary = makeDiffSummary(path: path, oldText: oldText, newText: newText)
            return ToolResult(output: summary, isError: false)
        } catch PathError.outsideCwd {
            return ToolResult.error(.outsideCwd, message: "Path '\(path)' is outside the working directory")
        } catch {
            return ToolResult.error(.executionFailed, message: "Failed to edit '\(path)': \(error.localizedDescription)")
        }
    }

    // MARK: - Diff Summary

    private func makeDiffSummary(path: String, oldText: String, newText: String) -> String {
        let wasTruncated = oldText.count > maxDiffPreviewChars || newText.count > maxDiffPreviewChars

        var lines = ["Edited \(path) (1 replacement)", "--- old", "+++ new"]
        lines.append(contentsOf: formatDiffLines(oldText, marker: "-", maxChars: maxDiffPreviewChars))
        lines.append(contentsOf: formatDiffLines(newText, marker: "+", maxChars: maxDiffPreviewChars))

        if wasTruncated {
            lines.append("[diff truncated: exceeded limit]")
        }

        return lines.joined(separator: "\n")
    }
}

private func formatDiffLines(_ text: String, marker: String, maxChars: Int) -> [String] {
    let preview: String
    if text.count <= maxChars {
        preview = text
    } else {
        // 截断到最近的换行符，避免半截行
        let prefix = String(text.prefix(maxChars))
        if let idx = prefix.lastIndex(of: "\n") {
            preview = String(prefix[..<idx])
        } else {
            preview = prefix
        }
    }

    return preview.split(separator: "\n", omittingEmptySubsequences: false)
        .map { "\(marker)\($0)" }
}
