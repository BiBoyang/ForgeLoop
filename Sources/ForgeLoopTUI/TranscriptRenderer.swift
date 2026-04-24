import Foundation

/// Transcript 渲染器：将 `CoreRenderEvent` 转换为终端可显示的行序列。
///
/// 行模型约束：每个 transcript 元素 = 1 逻辑行，不内嵌 \n。
/// 物理行预算与清屏行数均基于逻辑行数计算，内嵌 \n 会导致低估。
@MainActor
public final class TranscriptRenderer {
    public let lines: TranscriptBuffer
    private var streamingRange: Range<Int>?
    private var pendingTools: [String: Int] = [:]
    private var notificationLines: [Int] = []
    private let markdownEngine: MarkdownEngine

    public var pendingToolCount: Int { pendingTools.count }

    private let maxSummaryChars = 120
    private let maxSummaryLines = 3
    private let maxNotificationLines = 3

    public init(markdownEngine: MarkdownEngine = StreamingMarkdownEngine()) {
        self.lines = TranscriptBuffer()
        self.markdownEngine = markdownEngine
    }

    // MARK: - Core Entry Point

    public func applyCore(_ event: CoreRenderEvent) {
        switch event {
        case .insert(let newLines):
            for line in newLines {
                append(line)
            }

        case .blockStart:
            let start = lines.count
            streamingRange = start..<start
            markdownEngine.reset()

        case .blockUpdate(_, let newLines):
            replaceStreaming(with: renderMarkdown(lines: newLines, isFinal: false))

        case .blockEnd(_, let newLines, let footer):
            replaceStreaming(with: renderMarkdown(lines: newLines, isFinal: true))
            streamingRange = nil
            markdownEngine.reset()
            append("")

            if let footer = footer, !footer.isEmpty {
                let trimmed = footer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    append("[error] \(trimmed)")
                    append("")
                }
            }

        case .operationStart(let id, let header, let status):
            append(header)
            append(status)
            pendingTools[id] = lines.count - 1

        case .operationEnd(let id, let isError, let result):
            guard let lineIndex = pendingTools.removeValue(forKey: id) else { break }
            let prefix = isError ? "⎿ failed" : "⎿ done"
            let previewLines = formatToolResult(result)
            let resultLines: [String]
            if previewLines.isEmpty {
                resultLines = [prefix]
            } else {
                resultLines = previewLines.map { "\(prefix): \($0)" }
            }
            lines.replace(range: lineIndex..<(lineIndex + 1), with: resultLines)
            let delta = resultLines.count - 1
            if delta != 0 {
                shiftIndices(after: lineIndex, by: delta)
            }

        case .notification(let text):
            appendNotification("▸ \(text)")
        }
    }

    // MARK: - Legacy Bridge

    @available(*, deprecated, message: "Use applyCore(_:) with CoreRenderEvent instead")
    public func apply(_ event: RenderEvent) {
        applyCore(LegacyRenderEventAdapter.adapt(event))
    }

    // MARK: - Tool Result Formatting

    /// 格式化工具结果为多条逻辑行（不内嵌 \n）。
    /// 行数上限 maxSummaryLines，每行字符上限 maxSummaryChars。
    private func formatToolResult(_ text: String?) -> [String] {
        guard let text = text, !text.isEmpty else { return [] }

        let allLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var previewLines = Array(allLines.prefix(maxSummaryLines))

        if allLines.count > maxSummaryLines {
            previewLines.append("...")
        }

        return previewLines.map { line in
            if line.count > maxSummaryChars {
                let endIndex = line.index(line.startIndex, offsetBy: maxSummaryChars)
                return String(line[..<endIndex]) + "..."
            }
            return line
        }
    }

    // MARK: - Notification Folding

    /// 通知行最多保留 maxNotificationLines 条；超出时真实删除旧通知并同步所有索引。
    private func appendNotification(_ line: String) {
        lines.append(line)
        notificationLines.append(lines.count - 1)

        while notificationLines.count > maxNotificationLines {
            let oldIndex = notificationLines.removeFirst()
            lines.replace(range: oldIndex..<(oldIndex + 1), with: [])
            shiftIndices(after: oldIndex - 1, by: -1)
        }
    }

    // MARK: - Index Shifting

    /// 当 transcript 行数发生变化（插入或删除）时，同步所有基于行号的索引。
    private func shiftIndices(after threshold: Int, by delta: Int) {
        for (toolCallId, lineIdx) in pendingTools {
            if lineIdx > threshold {
                pendingTools[toolCallId] = lineIdx + delta
            }
        }
        for i in 0..<notificationLines.count {
            if notificationLines[i] > threshold {
                notificationLines[i] += delta
            }
        }
        if let range = streamingRange {
            let newLower = range.lowerBound > threshold ? range.lowerBound + delta : range.lowerBound
            let newUpper = range.upperBound > threshold ? range.upperBound + delta : range.upperBound
            streamingRange = newLower..<newUpper
        }
    }

    // MARK: - Streaming

    private func replaceStreaming(with newLines: [String]) {
        let range = streamingRange ?? (lines.count..<lines.count)
        lines.replace(range: range, with: newLines)
        streamingRange = range.lowerBound..<(range.lowerBound + newLines.count)
    }

    private func renderMarkdown(lines rawLines: [String], isFinal: Bool) -> [String] {
        guard !rawLines.isEmpty else { return [] }

        var prefixLines: [String] = []
        var contentStart = 0
        for (index, line) in rawLines.enumerated() {
            let plain = ansiStripped(line)
            if plain.hasPrefix("💭 ") {
                prefixLines.append(line)
                contentStart = index + 1
                continue
            }
            break
        }

        let contentLines = Array(rawLines.dropFirst(contentStart))
        guard !contentLines.isEmpty else { return prefixLines }
        let text = contentLines.joined(separator: "\n")
        let rendered = markdownEngine.render(text: text, isFinal: isFinal)
        return prefixLines + rendered
    }

    private func append(_ line: String) {
        lines.append(line)
    }
}

@MainActor
public final class TranscriptBuffer {
    public init() {}

    public private(set) var all: [String] = []

    public var count: Int { all.count }

    public func append(_ line: String) {
        all.append(line)
    }

    public func replace(range: Range<Int>, with lines: [String]) {
        let lower = max(0, min(range.lowerBound, all.count))
        let upper = max(lower, min(range.upperBound, all.count))
        all.replaceSubrange(lower..<upper, with: lines)
    }
}
