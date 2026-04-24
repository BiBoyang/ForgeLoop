import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI

// MARK: - Core Adapter (New)

/// 将 `AgentEvent` 单点转换为 `CoreRenderEvent`；所有 Agent->TUI 边界收敛于此。
func toCoreRenderEvent(_ event: AgentEvent) -> CoreRenderEvent? {
    switch event {
    case .agentStart:
        return .notification(text: "agent started")
    case .agentEnd:
        return .notification(text: "agent ended")
    case .turnStart, .turnEnd:
        return nil
    case .messageStart(let message):
        return adaptMessageStart(message)
    case .messageUpdate(let assistant, _):
        let (text, thinking) = extractAssistantContent(assistant)
        let lines = formatAssistantLines(text: text, thinking: thinking)
        return .blockUpdate(id: "__assistant", lines: lines)
    case .messageEnd(let message):
        return adaptMessageEnd(message)
    case .toolExecutionStart(let toolCallId, let toolName, let args):
        return .operationStart(
            id: toolCallId,
            header: "● \(toolName)(\(args))",
            status: "⎿ running..."
        )
    case .toolExecutionEnd(let toolCallId, _, let isError, let summary):
        return .operationEnd(id: toolCallId, isError: isError, result: summary)
    }
}

// MARK: - Legacy Adapter (Deprecated)

@available(*, deprecated, message: "Use toCoreRenderEvent instead")
func toRenderEvent(_ event: AgentEvent) -> RenderEvent? {
    switch event {
    case .agentStart:
        return .notification(text: "agent started")
    case .agentEnd:
        return .notification(text: "agent ended")
    case .turnStart:
        return nil
    case .turnEnd:
        return nil
    case .messageStart(let message):
        return .messageStart(message: toRenderMessage(message))
    case .messageUpdate(let assistant, _):
        let (text, thinking) = extractAssistantContent(assistant)
        return .messageUpdate(
            message: .assistant(
                text: text,
                thinking: thinking,
                errorMessage: assistant.errorMessage
            )
        )
    case .messageEnd(let message):
        return .messageEnd(message: toRenderMessage(message))
    case .toolExecutionStart(let toolCallId, let toolName, let args):
        return .toolExecutionStart(toolCallId: toolCallId, toolName: toolName, args: args)
    case .toolExecutionEnd(let toolCallId, let toolName, let isError, let summary):
        return .toolExecutionEnd(toolCallId: toolCallId, toolName: toolName, isError: isError, summary: summary)
    }
}

// MARK: - Private Helpers

private func adaptMessageStart(_ message: Message) -> CoreRenderEvent? {
    switch message {
    case .user(let user):
        return .insert(lines: [Style.user("❯ " + user.text), ""])
    case .assistant:
        return .blockStart(id: "__assistant")
    case .tool:
        return nil
    }
}

private func adaptMessageEnd(_ message: Message) -> CoreRenderEvent? {
    switch message {
    case .user:
        return nil
    case .assistant(let assistant):
        let (text, thinking) = extractAssistantContent(assistant)
        let lines = formatAssistantLines(text: text, thinking: thinking)
        let footer = text.isEmpty ? assistant.errorMessage : nil
        return .blockEnd(id: "__assistant", lines: lines, footer: footer)
    case .tool:
        return nil
    }
}

@available(*, deprecated)
private func toRenderMessage(_ message: Message) -> RenderMessage {
    switch message {
    case .user(let user):
        return .user(user.text)
    case .assistant(let assistant):
        let (text, thinking) = extractAssistantContent(assistant)
        return .assistant(text: text, thinking: thinking, errorMessage: assistant.errorMessage)
    case .tool(let tool):
        return .tool(toolCallId: tool.toolCallId, output: tool.output, isError: tool.isError)
    }
}

private func formatAssistantLines(text: String, thinking: String?) -> [String] {
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
