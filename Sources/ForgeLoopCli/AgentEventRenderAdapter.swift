import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI

func toRenderEvent(_ event: AgentEvent) -> RenderEvent? {
    switch event {
    case .messageStart(let message):
        return .messageStart(message: toRenderMessage(message))
    case .messageUpdate(let assistant, _):
        return .messageUpdate(
            message: .assistant(
                text: assistantText(assistant),
                errorMessage: assistant.errorMessage
            )
        )
    case .messageEnd(let message):
        return .messageEnd(message: toRenderMessage(message))
    case .toolExecutionStart(let toolCallId, let toolName, let args):
        return .toolExecutionStart(toolCallId: toolCallId, toolName: toolName, args: args)
    case .toolExecutionEnd(let toolCallId, let toolName, let isError, let summary):
        return .toolExecutionEnd(toolCallId: toolCallId, toolName: toolName, isError: isError, summary: summary)
    default:
        return nil
    }
}

private func toRenderMessage(_ message: Message) -> RenderMessage {
    switch message {
    case .user(let user):
        return .user(user.text)
    case .assistant(let assistant):
        return .assistant(
            text: assistantText(assistant),
            errorMessage: assistant.errorMessage
        )
    case .tool(let tool):
        return .tool(toolCallId: tool.toolCallId, output: tool.output, isError: tool.isError)
    }
}

private func assistantText(_ assistant: AssistantMessage) -> String {
    assistant.content.compactMap { block -> String? in
        if case .text(let text) = block {
            return text.text
        }
        return nil
    }.joined(separator: "\n")
}
