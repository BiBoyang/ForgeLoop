import Foundation

public enum StopReason: String, Sendable, Hashable, Codable {
    case endTurn
    case toolUse
    case aborted
    case error
}

public struct TextContent: Sendable, Hashable, Codable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct ToolCall: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public enum AssistantBlock: Sendable, Hashable, Codable {
    case text(TextContent)
    case toolCall(ToolCall)
}

public struct UserMessage: Sendable, Hashable, Codable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct AssistantMessage: Sendable, Hashable, Codable {
    public var content: [AssistantBlock]
    public var stopReason: StopReason
    public var errorMessage: String?

    public init(
        content: [AssistantBlock] = [],
        stopReason: StopReason = .endTurn,
        errorMessage: String? = nil
    ) {
        self.content = content
        self.stopReason = stopReason
        self.errorMessage = errorMessage
    }

    public static func text(_ value: String, stopReason: StopReason = .endTurn) -> AssistantMessage {
        AssistantMessage(
            content: [.text(TextContent(text: value))],
            stopReason: stopReason
        )
    }
}

public struct ToolResultMessage: Sendable, Hashable, Codable {
    public var toolCallId: String
    public var output: String
    public var isError: Bool

    public init(toolCallId: String, output: String, isError: Bool = false) {
        self.toolCallId = toolCallId
        self.output = output
        self.isError = isError
    }
}

public enum Message: Sendable, Hashable, Codable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case tool(ToolResultMessage)

    public var role: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        }
    }
}
