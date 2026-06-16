import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI

// MARK: - Core Adapter (New)

/// 将 `AgentEvent` 单点转换为 `CoreRenderEvent` 序列；所有 Agent->TUI 边界收敛于此。
///
/// - Parameter event: 待转换的 Agent 事件。
/// - Parameter blockID: 当前 assistant message 的 session-scoped block ID。
///   由 CodingTUI 在 `.messageStart(.assistant)` 时生成，并贯穿同一次回复的
///   `.messageUpdate` / `.messageEnd`。
func toCoreRenderEvent(_ event: AgentEvent, blockID: String = "__assistant") -> [CoreRenderEvent] {
    switch event {
    case .agentStart:
        return [.notification(text: "agent started")]
    case .agentEnd:
        return [.notification(text: "agent ended")]
    case .turnStart, .turnEnd:
        return []
    case .messageStart(let message):
        return adaptMessageStart(message, blockID: blockID).map { [$0] } ?? []
    case .messageUpdate(let assistant, _):
        return adaptAssistantUpdate(assistant, blockID: blockID, isFinal: false)
    case .messageEnd(let message):
        return adaptMessageEnd(message, blockID: blockID)
    case .toolExecutionStart(let toolCallId, let toolName, let args):
        return [.operationStart(
            id: toolCallId,
            header: "● \(toolName)(\(args))",
            status: "⎿ running..."
        )]
    case .toolExecutionEnd(let toolCallId, _, let isError, let summary):
        return [.operationEnd(id: toolCallId, isError: isError, result: summary)]
    case .contextCompacted:
        return []
    }
}

// MARK: - Private Helpers

private func adaptMessageStart(_ message: Message, blockID: String) -> CoreRenderEvent? {
    switch message {
    case .user(let user):
        return .insert(lines: prefixedLogicalLines(prefix: Style.user("❯ "), text: user.text) + [""])
    case .assistant:
        return .blockStart(id: blockID)
    case .tool:
        return nil
    }
}

private func adaptAssistantUpdate(_ assistant: AssistantMessage, blockID: String, isFinal: Bool) -> [CoreRenderEvent] {
    var events: [CoreRenderEvent] = []
    let (text, thinking) = extractAssistantContent(assistant)

    if let thinking = thinking {
        events.append(.thinking(content: thinking, isFinal: isFinal))
    }

    let textLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if !textLines.isEmpty {
        events.append(.blockUpdate(id: blockID, lines: textLines))
    }

    return events
}

private func adaptMessageEnd(_ message: Message, blockID: String) -> [CoreRenderEvent] {
    switch message {
    case .user:
        return []
    case .assistant(let assistant):
        var events: [CoreRenderEvent] = []
        let (text, thinking) = extractAssistantContent(assistant)

        // Finalize thinking first so its range is cleaned before blockEnd.
        if thinking != nil {
            events.append(.thinking(content: thinking ?? "", isFinal: true))
        }

        let textLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let footer = text.isEmpty ? assistant.errorMessage : nil
        events.append(.blockEnd(id: blockID, lines: textLines, footer: footer))
        return events
    case .tool:
        return []
    }
}

/// 提取 assistant content：
/// - text blocks → 普通文本
/// - toolCall blocks → 显式忽略（避免与 toolExecutionStart/End 双写）
/// - <thinking>...</thinking> → 提取为 thinking 内容
private func extractAssistantContent(_ assistant: AssistantMessage) -> (text: String, thinking: String?) {
    var texts: [String] = []
    var thinkingParts: [String] = []

    for block in assistant.content {
        switch block {
        case .text(let textContent):
            let text = textContent.text
            if let thinking = extractThinking(from: text) {
                thinkingParts.append(thinking)
            } else {
                texts.append(text)
            }
        case .toolCall:
            // Intentionally ignored: tool calls are rendered separately
            // via toolExecutionStart / toolExecutionEnd to avoid duplication.
            break
        }
    }

    let text = texts.joined(separator: "\n")
    let thinking = thinkingParts.isEmpty ? nil : thinkingParts.joined(separator: "\n")
    return (text, thinking)
}

/// 从文本中提取 <thinking>...</thinking> 包裹的内容。
/// 返回 nil 表示不含 thinking 标签。
private func extractThinking(from text: String) -> String? {
    guard text.hasPrefix("<thinking>") else { return nil }

    if let endRange = text.range(of: "</thinking>") {
        let start = text.index(text.startIndex, offsetBy: 10)
        return String(text[start..<endRange.lowerBound])
    }

    // Unclosed thinking tag (streaming partial)
    return String(text.dropFirst(10))
}
