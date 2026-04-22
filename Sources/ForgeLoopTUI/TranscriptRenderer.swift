import Foundation

@MainActor
public final class TranscriptRenderer {
    public let lines: TranscriptBuffer
    private var streamingRange: Range<Int>?
    private var pendingTools: [String: Int] = [:]

    public var pendingToolCount: Int { pendingTools.count }

    private let maxSummaryRenderLength = 120

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
            guard case .assistant = message else { break }
            replaceStreaming(with: renderAssistantLines(message))
        case .messageEnd(let message):
            guard case .assistant = message else { break }
            replaceStreaming(with: renderAssistantLines(message))
            streamingRange = nil
            append("")
        case .toolExecutionStart(let toolCallId, let toolName, let args):
            append("● \(toolName)(\(args))")
            append("⎿ running...")
            pendingTools[toolCallId] = lines.count - 1
        case .toolExecutionEnd(let toolCallId, _, let isError, let summary):
            guard let lineIndex = pendingTools.removeValue(forKey: toolCallId) else { break }
            let prefix = isError ? "⎿ failed" : "⎿ done"
            let suffix = truncateIfNeeded(summary ?? "")
            let result = suffix.isEmpty ? prefix : "\(prefix): \(suffix)"
            lines.replace(range: lineIndex..<(lineIndex + 1), with: [result])
        }
    }

    private func truncateIfNeeded(_ text: String) -> String {
        if text.count <= maxSummaryRenderLength { return text }
        let endIndex = text.index(text.startIndex, offsetBy: maxSummaryRenderLength)
        return String(text[..<endIndex]) + "..."
    }

    private func renderAssistantLines(_ message: RenderMessage) -> [String] {
        guard case .assistant(let text, let errorMessage) = message else {
            return [""]
        }

        if !text.isEmpty {
            return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }

        if
            let error = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
            !error.isEmpty
        {
            return ["[error] \(error)"]
        }

        return [""]
    }

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
