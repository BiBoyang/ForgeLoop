import Foundation
import ForgeLoopAI

public struct FindTool: Tool {
    public let name = "find"
    public let maxDepth: Int
    public let maxResults: Int
    public let maxFilesScanned: Int

    public init(maxDepth: Int = 6, maxResults: Int = 200, maxFilesScanned: Int = 10_000) {
        self.maxDepth = maxDepth
        self.maxResults = maxResults
        self.maxFilesScanned = maxFilesScanned
    }

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        let args = parseArgs(arguments)
        let path = args?["path"] ?? "."
        let namePattern = args?["namePattern"] ?? "*"

        let guard_ = PathGuard(cwd: cwd)
        do {
            let url = try guard_.resolve(path)

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists else {
                return ToolResult.error(.pathNotFound, message: "Path not found: \(path)")
            }
            guard isDir.boolValue else {
                return ToolResult.error(.targetNotDirectory, message: "Path '\(path)' is not a directory")
            }

            let pattern = namePattern
                .replacingOccurrences(of: "*", with: ".*")
                .replacingOccurrences(of: "?", with: ".")
            let regex = try NSRegularExpression(pattern: "^\(pattern)$", options: [.caseInsensitive])

            var results: [String] = []
            var filesScanned = 0
            var truncated = false

            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            while let itemURL = enumerator?.nextObject() as? URL {
                if cancellation?.isCancelled == true {
                    return ToolResult.error(.cancelled, message: "Search aborted")
                }

                // Check depth using standardized path components to handle /private symlink prefix
                let baseComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                let itemComponents = itemURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                let depth = itemComponents.count - baseComponents.count
                guard depth <= maxDepth else {
                    enumerator?.skipDescendants()
                    continue
                }

                filesScanned += 1
                if filesScanned > maxFilesScanned {
                    truncated = true
                    break
                }

                let name = itemURL.lastPathComponent
                let range = NSRange(location: 0, length: name.utf16.count)
                if regex.firstMatch(in: name, options: [], range: range) != nil {
                    let itemStd = itemURL.standardizedFileURL.resolvingSymlinksInPath()
                    let urlStd = url.standardizedFileURL.resolvingSymlinksInPath()
                    let relativePath = String(itemStd.path.dropFirst(urlStd.path.count + 1))
                    results.append(relativePath)
                    if results.count >= maxResults {
                        truncated = true
                        break
                    }
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
            return ToolResult.error(.executionFailed, message: "Failed to search '\(path)': \(error.localizedDescription)")
        }
    }
}
