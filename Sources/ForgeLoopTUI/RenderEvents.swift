import Foundation

// MARK: - Legacy Chat-Semantic Models (Deprecated)

@available(*, deprecated, message: "Use CoreRenderEvent instead")
public enum RenderMessage: Sendable, Equatable {
    case user(String)
    case assistant(text: String, thinking: String?, errorMessage: String?)
    case tool(toolCallId: String, output: String, isError: Bool)
}

@available(*, deprecated, message: "Use CoreRenderEvent instead")
public enum RenderEvent: Sendable, Equatable {
    case messageStart(message: RenderMessage)
    case messageUpdate(message: RenderMessage)
    case messageEnd(message: RenderMessage)
    case toolExecutionStart(toolCallId: String, toolName: String, args: String)
    case toolExecutionEnd(toolCallId: String, toolName: String, isError: Bool, summary: String?)
    case notification(text: String)
}

// MARK: - Legacy Adapter

/// 将旧 `RenderEvent` 转换为 `CoreRenderEvent`。
///
/// 保留用于向后兼容；新项目应直接使用 `CoreRenderEvent`。
@available(*, deprecated, message: "Use CoreRenderEvent directly")
public struct LegacyRenderEventAdapter {
    private static let blockId = "__legacy_block"

    public static func adapt(_ event: RenderEvent) -> CoreRenderEvent {
        switch event {
        case .messageStart(let message):
            switch message {
            case .user(let text):
                return .insert(lines: [Style.user("❯ " + text), ""])
            case .assistant:
                return .blockStart(id: blockId)
            case .tool:
                return .insert(lines: [])
            }

        case .messageUpdate(let message):
            guard case .assistant(let text, let thinking, _) = message else {
                return .insert(lines: [])
            }
            return .blockUpdate(id: blockId, lines: formatAssistant(text: text, thinking: thinking))

        case .messageEnd(let message):
            switch message {
            case .user(let text):
                return .insert(lines: [Style.user("❯ " + text), ""])
            case .assistant(let text, let thinking, let errorMessage):
                let footer = text.isEmpty ? errorMessage : nil
                return .blockEnd(
                    id: blockId,
                    lines: formatAssistant(text: text, thinking: thinking),
                    footer: footer
                )
            case .tool:
                return .insert(lines: [])
            }

        case .toolExecutionStart(let toolCallId, let toolName, let args):
            return .operationStart(
                id: toolCallId,
                header: "● \(toolName)(\(args))",
                status: "⎿ running..."
            )

        case .toolExecutionEnd(let toolCallId, _, let isError, let summary):
            return .operationEnd(id: toolCallId, isError: isError, result: summary)

        case .notification(let text):
            return .notification(text: text)
        }
    }

    // MARK: - Private

    private static func formatAssistant(text: String, thinking: String?) -> [String] {
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
}
