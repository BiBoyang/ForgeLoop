import Foundation

/// Transcript 渲染器：将 RenderEvent 转换为终端可显示的行序列。
///
/// 行模型约束：每个 transcript 元素 = 1 逻辑行，不内嵌 \n。
/// 物理行预算与清屏行数均基于逻辑行数计算，内嵌 \n 会导致低估。
@MainActor
public final class TranscriptRenderer {
    public let lines: TranscriptBuffer
    private var streamingRange: Range<Int>?
    private var pendingTools: [String: Int] = [:]
    private var notificationLines: [Int] = []

    public var pendingToolCount: Int { pendingTools.count }

    private let maxSummaryChars = 120
    private let maxSummaryLines = 3
    private let maxNotificationLines = 3

    public init() {
        self.lines = TranscriptBuffer()
    }

    public func apply(_ event: RenderEvent) {
        switch event {
        case .messageStart(let message):
            switch message {
            case .user(let text):
                append(Style.user("❯ " + text))
                append("")
            case .assistant:
                let start = lines.count
                streamingRange = start..<start
            case .tool:
                break
            }

        case .messageUpdate(let message):
            guard case .assistant(let text, let thinking, _) = message else { break }
            replaceStreaming(with: renderAssistantLines(text: text, thinking: thinking))

        case .messageEnd(let message):
            guard case .assistant(let text, let thinking, let errorMessage) = message else { break }
            replaceStreaming(with: renderAssistantLines(text: text, thinking: thinking))
            streamingRange = nil
            append("")

            if text.isEmpty, let error = errorMessage {
                let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    append("[error] \(trimmed)")
                    append("")
                }
            }

        case .toolExecutionStart(let toolCallId, let toolName, let args):
            append("● \(toolName)(\(args))")
            append("⎿ running...")
            pendingTools[toolCallId] = lines.count - 1

        case .toolExecutionEnd(let toolCallId, _, let isError, let summary):
            guard let lineIndex = pendingTools.removeValue(forKey: toolCallId) else { break }
            let prefix = isError ? "⎿ failed" : "⎿ done"
            let previewLines = formatToolResult(summary)
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

    // MARK: - Assistant Lines

    private func renderAssistantLines(text: String, thinking: String?) -> [String] {
        var result: [String] = []

        if let thinking = thinking, !thinking.isEmpty {
            let firstLine = thinking.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? thinking
            let prefix = thinking.contains("\n") ? "💭 \(firstLine) …" : "💭 \(firstLine)"
            result.append(Style.dimmed(prefix))
        }

        if !text.isEmpty {
            result.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }

        return result
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
