import Foundation
import ForgeLoopAI

private let editToolSchema = ToolArgsSchema(fields: [
    ToolArgField(name: "path", type: .string, required: true),
    ToolArgField(name: "oldText", type: .string, required: true),
    ToolArgField(name: "newText", type: .string, required: true),
    ToolArgField(name: "anchor", type: .string, required: false),
    ToolArgField(name: "lineNumber", type: .int, required: false),
    ToolArgField(name: "replaceAll", type: .bool, required: false),
    ToolArgField(name: "caseInsensitive", type: .bool, required: false)
])

public struct EditTool: Tool {
    public let name = "edit"
    public let maxFileSize: Int
    public let maxDiffPreviewChars: Int

    public init(maxFileSize: Int = 1_048_576, maxDiffPreviewChars: Int = 200) {
        self.maxFileSize = maxFileSize
        self.maxDiffPreviewChars = maxDiffPreviewChars
    }

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        let validation = ToolArgsValidator.validate(arguments, schema: editToolSchema)
        let args: ValidatedArgs
        switch validation {
        case .success(let validated):
            args = validated
        case .failure(let errors):
            return ToolArgsValidator.formatErrors(errors)
        }

        guard let path = args.string("path"),
              let oldText = args.string("oldText"),
              let newText = args.string("newText") else {
            return ToolResult.error(.missingArgument, message: "Missing required arguments: path, oldText, newText")
        }

        let anchor = args.string("anchor")
        let lineNumber = args.int("lineNumber")
        let replaceAll = args.bool("replaceAll") ?? false
        let caseInsensitive = args.bool("caseInsensitive") ?? false

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

            // Determine the search region.
            var searchRegion = content[...]
            if let anchor = anchor {
                guard let anchorRange = content.range(of: anchor) else {
                    return ToolResult.error(.textNotFound, message: "Could not find anchor '\(anchor)' in \(path)")
                }
                searchRegion = content[anchorRange.upperBound...]
            }

            let compareOptions: String.CompareOptions = caseInsensitive ? .caseInsensitive : []

            // Optionally restrict to a specific line number.
            if let lineNumber = lineNumber {
                let lines = content.components(separatedBy: .newlines)
                guard lineNumber >= 1, lineNumber <= lines.count else {
                    return ToolResult.error(.textNotFound, message: "Line number \(lineNumber) is out of range in \(path)")
                }
                let targetLine = lines[lineNumber - 1]
                guard targetLine.localizedStandardContains(oldText) else {
                    return ToolResult.error(.textNotFound, message: "Could not find oldText on line \(lineNumber) in \(path)")
                }
                // Replace only within the target line.
                let lineStartIndex = content.index(content.startIndex, offsetBy: lines.prefix(lineNumber - 1).joined(separator: "\n").count)
                let lineStart = lineNumber == 1 ? content.startIndex : content.index(lineStartIndex, offsetBy: 1)
                let lineEnd = content.index(lineStart, offsetBy: targetLine.count)
                let lineRange = lineStart..<lineEnd

                guard let matchRange = content[lineRange].range(of: oldText, options: compareOptions) else {
                    return ToolResult.error(.textNotFound, message: "Could not find oldText on line \(lineNumber) in \(path)")
                }
                let actualStart = content.index(lineStart, offsetBy: content.distance(from: lineRange.lowerBound, to: matchRange.lowerBound))
                let actualEnd = content.index(actualStart, offsetBy: oldText.count)

                // When a disambiguator is provided, require a unique match within the region.
                if !replaceAll {
                    let matchCount = countOccurrences(of: oldText, in: content[lineRange], options: compareOptions)
                    if matchCount > 1 {
                        return ToolResult.error(.textNotFound, message: "Found \(matchCount) matches for oldText on line \(lineNumber) in \(path); use replaceAll=true to replace all")
                    }
                }

                // Write backup before mutation.
                try writeBackup(content: content, originalURL: url)
                content.replaceSubrange(actualStart..<actualEnd, with: newText)
                try content.write(to: url, atomically: true, encoding: .utf8)

                let summary = makeDiffSummary(path: path, oldText: oldText, newText: newText, replacements: 1)
                return ToolResult(output: summary, isError: false)
            }

            // Count matches in the search region.
            let matchCount = countOccurrences(of: oldText, in: searchRegion, options: compareOptions)
            guard matchCount > 0 else {
                return ToolResult.error(.textNotFound, message: "Could not find the text to replace in \(path)")
            }

            // When an anchor narrows the region, require a unique match unless replaceAll is set.
            if anchor != nil, !replaceAll, matchCount > 1 {
                return ToolResult.error(.textNotFound, message: "Found \(matchCount) matches for oldText after anchor in \(path); use replaceAll=true to replace all")
            }

            // Write backup before mutation.
            try writeBackup(content: content, originalURL: url)

            var replacements = 0
            if replaceAll {
                content = replacingAllOccurrences(
                    in: content,
                    of: oldText,
                    with: newText,
                    searchRegionStart: anchor != nil ? content.range(of: anchor!)?.upperBound : content.startIndex,
                    options: compareOptions
                )
                replacements = matchCount
            } else {
                guard let range = content.range(of: oldText, options: compareOptions, range: searchRegion.startIndex..<searchRegion.endIndex) else {
                    return ToolResult.error(.textNotFound, message: "Could not find the text to replace in \(path)")
                }
                content.replaceSubrange(range, with: newText)
                replacements = 1
            }
            try content.write(to: url, atomically: true, encoding: .utf8)

            let summary = makeDiffSummary(path: path, oldText: oldText, newText: newText, replacements: replacements)
            return ToolResult(output: summary, isError: false)
        } catch PathError.outsideCwd {
            return ToolResult.error(.outsideCwd, message: "Path '\(path)' is outside the working directory")
        } catch {
            return ToolResult.error(.executionFailed, message: "Failed to edit '\(path)': \(error.localizedDescription)")
        }
    }

    // MARK: - Backup

    private func writeBackup(content: String, originalURL: URL) throws {
        let backupURL = originalURL.appendingPathExtension("bak")
        try content.write(to: backupURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Matching helpers

    private func countOccurrences(of substring: String, in region: Substring, options: String.CompareOptions) -> Int {
        var count = 0
        var searchStart = region.startIndex
        let searchEnd = region.endIndex
        while let range = region.range(of: substring, options: options, range: searchStart..<searchEnd) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    private func replacingAllOccurrences(
        in content: String,
        of oldText: String,
        with newText: String,
        searchRegionStart: String.Index?,
        options: String.CompareOptions
    ) -> String {
        guard let start = searchRegionStart else { return content }
        var result = content
        var searchStart = start
        while let range = result.range(of: oldText, options: options, range: searchStart..<result.endIndex) {
            result.replaceSubrange(range, with: newText)
            searchStart = result.index(range.lowerBound, offsetBy: newText.count)
        }
        return result
    }

    // MARK: - Diff Summary

    private func makeDiffSummary(path: String, oldText: String, newText: String, replacements: Int) -> String {
        let wasTruncated = oldText.count > maxDiffPreviewChars || newText.count > maxDiffPreviewChars

        var lines = ["Edited \(path) (\(replacements) replacement\(replacements == 1 ? "" : "s"))", "--- old", "+++ new"]
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
