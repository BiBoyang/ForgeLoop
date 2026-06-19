import Foundation
import ForgeLoopAI

/// Error raised when a subagent run is cancelled before it completes naturally.
public struct SubagentCancellationError: Error, Sendable {}

/// Result returned by a subagent run.
public struct SubagentResult: Sendable {
    /// Final assistant response text from the subagent.
    public let text: String
    /// Number of tool calls made by the subagent.
    public let toolCalls: Int
    /// Full transcript of the subagent run.
    public let messages: [Message]
}

/// Creates a child agent from the given subagent definition, runs the task prompt,
/// and returns the collected result.
///
/// The child agent inherits the parent's model, cwd, auth, and stream function,
/// but starts with an independent transcript and a filtered tool set.
public func runSubagent(
    definition: SubagentDefinition,
    taskPrompt: String,
    parentConfig: CodingAgentConfig,
    parentSessionId: String,
    cancellation: CancellationHandle? = nil
) async throws -> SubagentResult {
    var childConfig = parentConfig
    childConfig.systemPrompt = definition.prompt
    childConfig.subagents = []

    let toolExecutor = ToolExecutor()
    registerAllowedTools(into: toolExecutor, for: definition.tools)

    let childAgent = Agent(
        initialState: AgentInitialState(
            systemPrompt: childConfig.systemPrompt ?? buildSystemPrompt(cwd: childConfig.cwd),
            model: childConfig.model
        ),
        streamFn: childConfig.streamFn,
        toolExecutor: toolExecutor,
        cwd: childConfig.cwd
    )
    childAgent.toolExecutionMode = childConfig.toolExecutionMode

    // Propagate cancellation from both the caller Task and the explicit handle.
    cancellation?.onCancel { _ in childAgent.abort() }
    try await withTaskCancellationHandler {
        try await childAgent.prompt(taskPrompt)
        await childAgent.waitForIdle()
    } onCancel: {
        childAgent.abort()
    }

    // If the run was cancelled, surface it as an error instead of returning partial/empty text.
    guard !Task.isCancelled, cancellation?.isCancelled != true else {
        throw SubagentCancellationError()
    }

    let messages = childAgent.state.messages
    let toolCalls = messages.compactMap { message -> Int? in
        guard case .assistant(let assistant) = message else { return nil }
        return assistant.content.reduce(0) { count, block in
            if case .toolCall = block { return count + 1 }
            return count
        }
    }.reduce(0, +)

    let text = messages.reversed().compactMap { message -> String? in
        guard case .assistant(let assistant) = message else { return nil }
        return assistant.content.compactMap { block -> String? in
            if case .text(let textContent) = block { return textContent.text }
            return nil
        }.joined()
    }.first ?? ""

    return SubagentResult(text: text, toolCalls: toolCalls, messages: messages)
}

private func registerAllowedTools(into executor: ToolExecutor, for tools: SubagentTools) {
    let allowedNames = allowedToolNames(for: tools)
    let bgManager = BackgroundTaskManager()

    let allTools: [(String, () -> any Tool)] = [
        ("read", { ReadTool() }),
        ("write", { WriteTool() }),
        ("edit", { EditTool() }),
        ("list", { ListTool() }),
        ("find", { FindTool() }),
        ("grep", { GrepTool() }),
        ("bash", { BashTool(manager: bgManager) }),
        ("bg", { BgTool(manager: bgManager) }),
        ("bg_status", { BgStatusTool(manager: bgManager) })
    ]

    for (name, factory) in allTools {
        if allowedNames == nil || allowedNames!.contains(name) {
            executor.register(factory())
        }
    }
}

private func allowedToolNames(for tools: SubagentTools) -> Set<String>? {
    switch tools {
    case .all:
        return nil
    case .readOnly:
        return ["read", "find", "grep", "list"]
    case .custom(let names):
        return Set(names)
    }
}
