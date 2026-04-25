import Foundation
import ForgeLoopAI

private let grepToolSchema = ToolArgsSchema(fields: [
    ToolArgField(name: "path", type: .string, required: true),
    ToolArgField(name: "pattern", type: .string, required: true)
])

public struct GrepTool: Tool {
    public let name = "grep"
    public let maxResults: Int
    public let maxFileSize: Int

    public init(maxResults: Int = 200, maxFileSize: Int = 1_048_576) {
        self.maxResults = maxResults
        self.maxFileSize = maxFileSize
    }

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        let validation = ToolArgsValidator.validate(arguments, schema: grepToolSchema)
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
        guard let pattern = args.string("pattern") else {
            return ToolResult.error(.invalidType, message: "Invalid type for pattern: expected string", hint: "path: $.pattern")
        }

        let guard_ = PathGuard(cwd: cwd)
        do {
            let url = try guard_.resolve(path)

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists else {
                return ToolResult.error(.pathNotFound, message: "Path not found: \(path)")
            }

            var results: [String] = []
            var truncated = false

            if isDir.boolValue {
                // Search recursively in directory
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )

                while let itemURL = enumerator?.nextObject() as? URL {
                    if cancellation?.isCancelled == true {
                        return ToolResult.error(.cancelled, message: "Search aborted")
                    }

                    let itemIsDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard !itemIsDir else { continue }

                    let fileSize = (try? itemURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard fileSize <= maxFileSize else { continue }

                    let itemStd = itemURL.standardizedFileURL.resolvingSymlinksInPath()
                    let urlStd = url.standardizedFileURL.resolvingSymlinksInPath()
                    let relativePath = String(itemStd.path.dropFirst(urlStd.path.count + 1))
                    let fileResults = searchInFile(at: itemURL, relativePath: relativePath, pattern: pattern)
                    results.append(contentsOf: fileResults)

                    if results.count >= maxResults {
                        truncated = true
                        results = Array(results.prefix(maxResults))
                        break
                    }
                }
            } else {
                // Search in single file
                let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard fileSize <= maxFileSize else {
                    return ToolResult.error(.sizeExceeded, message: "File exceeds maximum size limit")
                }
                results = searchInFile(at: url, relativePath: url.lastPathComponent, pattern: pattern)
                if results.count > maxResults {
                    truncated = true
                    results = Array(results.prefix(maxResults))
                }
            }

            if results.isEmpty {
                return ToolResult(output: "(no matches)", isError: false)
            }

            var output = results.joined(separator: "\n")
            if truncated {
                output += "\n[truncated: exceeded limit]"
            }
            return ToolResult(output: output, isError: false)
        } catch PathError.outsideCwd {
            return ToolResult.error(.outsideCwd, message: "Path '\(path)' is outside the working directory")
        } catch {
            return ToolResult.error(.executionFailed, message: "Failed to grep '\(path)': \(error.localizedDescription)")
        }
    }

    private func searchInFile(at url: URL, relativePath: String, pattern: String) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: .newlines)
        var matches: [String] = []

        for (index, line) in lines.enumerated() {
            if line.localizedStandardContains(pattern) {
                let lineNum = index + 1
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                matches.append("\(relativePath):\(lineNum):\(trimmed)")
            }
        }
        return matches
    }
}
