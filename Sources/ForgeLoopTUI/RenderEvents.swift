import Foundation

public enum RenderMessage: Sendable, Equatable {
    case user(String)
    case assistant(text: String, errorMessage: String?)
    case tool(toolCallId: String, output: String, isError: Bool)
}

public enum RenderEvent: Sendable, Equatable {
    case messageStart(message: RenderMessage)
    case messageUpdate(message: RenderMessage)
    case messageEnd(message: RenderMessage)
    case toolExecutionStart(toolCallId: String, toolName: String, args: String)
    case toolExecutionEnd(toolCallId: String, toolName: String, isError: Bool, summary: String?)
}
