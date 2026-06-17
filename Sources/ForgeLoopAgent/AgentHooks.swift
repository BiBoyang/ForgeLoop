import Foundation
import ForgeLoopAI

// MARK: - beforeToolCall

public struct BeforeToolCallContext: Sendable {
    public let toolName: String
    public let arguments: String

    public init(toolName: String, arguments: String) {
        self.toolName = toolName
        self.arguments = arguments
    }
}

public struct BeforeToolCallResult: Sendable {
    public var block: Bool
    public var reason: String?
    public var modifiedArguments: String?

    public init(block: Bool = false, reason: String? = nil, modifiedArguments: String? = nil) {
        self.block = block
        self.reason = reason
        self.modifiedArguments = modifiedArguments
    }
}

public typealias BeforeToolCallHook = @Sendable (
    _ toolName: String,
    _ arguments: String,
    _ cancellation: CancellationHandle?
) async -> BeforeToolCallResult?

// MARK: - afterToolCall

public struct AfterToolCallContext: Sendable {
    public let toolName: String
    public let arguments: String
    public let result: ToolResult

    public init(toolName: String, arguments: String, result: ToolResult) {
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
    }
}

public struct AfterToolCallResult: Sendable {
    public var modifiedResult: ToolResult?
    public var isError: Bool?

    public init(modifiedResult: ToolResult? = nil, isError: Bool? = nil) {
        self.modifiedResult = modifiedResult
        self.isError = isError
    }
}

public typealias AfterToolCallHook = @Sendable (
    _ toolName: String,
    _ arguments: String,
    _ result: ToolResult,
    _ cancellation: CancellationHandle?
) async -> AfterToolCallResult?

// MARK: - userPromptSubmit

public struct UserPromptSubmitContext: Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct UserPromptSubmitResult: Sendable {
    public var block: Bool
    public var reason: String?
    public var modifiedText: String?

    public init(block: Bool = false, reason: String? = nil, modifiedText: String? = nil) {
        self.block = block
        self.reason = reason
        self.modifiedText = modifiedText
    }
}

public typealias UserPromptSubmitHook = @Sendable (
    _ text: String,
    _ cancellation: CancellationHandle?
) async -> UserPromptSubmitResult?

// MARK: - betweenTurns

public struct BetweenTurnsContext: Sendable {
    public let messages: [Message]

    public init(messages: [Message]) {
        self.messages = messages
    }
}

public struct BetweenTurnsResult: Sendable {
    public var compactedMessages: [Message]?

    public init(compactedMessages: [Message]? = nil) {
        self.compactedMessages = compactedMessages
    }
}

public typealias BetweenTurnsHook = @Sendable (
    _ messages: [Message],
    _ cancellation: CancellationHandle?
) async -> BetweenTurnsResult?
