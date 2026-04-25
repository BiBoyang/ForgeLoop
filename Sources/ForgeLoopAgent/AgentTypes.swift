import Foundation
import ForgeLoopAI

public typealias AgentListener = @Sendable (AgentEvent, CancellationHandle?) async -> Void
public typealias Unsubscribe = @Sendable () -> Void
public typealias AgentEventSink = @Sendable (AgentEvent) async -> Void
public typealias StreamFn = @Sendable (Model, Context, StreamOptions?) async throws -> AssistantMessageStream

public struct AgentInitialState: Sendable {
    public var systemPrompt: String
    public var model: Model
    public var messages: [Message]

    public init(systemPrompt: String = "", model: Model, messages: [Message] = []) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.messages = messages
    }
}

public enum AgentError: Error, Equatable {
    case alreadyRunning
    case noMessagesToContinue
    case cannotContinueFromAssistant
}

public enum AgentEvent: Sendable {
    case agentStart
    case agentEnd(messages: [Message])
    case turnStart
    case turnEnd(message: Message)
    case messageStart(message: Message)
    case messageUpdate(message: AssistantMessage, assistantMessageEvent: AssistantMessageEvent)
    case messageEnd(message: Message)
    case toolExecutionStart(toolCallId: String, toolName: String, args: String)
    case toolExecutionEnd(toolCallId: String, toolName: String, isError: Bool, summary: String?)
    case contextCompacted(before: Int, after: Int)

    public var type: String {
        switch self {
        case .agentStart: return "agent_start"
        case .agentEnd: return "agent_end"
        case .turnStart: return "turn_start"
        case .turnEnd: return "turn_end"
        case .messageStart: return "message_start"
        case .messageUpdate: return "message_update"
        case .messageEnd: return "message_end"
        case .toolExecutionStart: return "tool_execution_start"
        case .toolExecutionEnd: return "tool_execution_end"
        case .contextCompacted: return "context_compacted"
        }
    }
}

public struct AgentContext: Sendable {
    public var systemPrompt: String
    public var messages: [Message]

    public init(systemPrompt: String, messages: [Message]) {
        self.systemPrompt = systemPrompt
        self.messages = messages
    }
}

public enum ToolExecutionMode: String, Sendable {
    case sequential
    case parallel
}

public struct AgentLoopConfig: Sendable {
    public var model: Model
    public var apiKeyResolver: (@Sendable (String) async -> String?)?
    public var toolExecutor: ToolExecutor?
    public var cwd: String
    public var toolExecutionMode: ToolExecutionMode

    public init(
        model: Model,
        apiKeyResolver: (@Sendable (String) async -> String?)? = nil,
        toolExecutor: ToolExecutor? = nil,
        cwd: String = "",
        toolExecutionMode: ToolExecutionMode = .sequential
    ) {
        self.model = model
        self.apiKeyResolver = apiKeyResolver
        self.toolExecutor = toolExecutor
        self.cwd = cwd
        self.toolExecutionMode = toolExecutionMode
    }
}
