import Foundation
import ForgeLoopAI

private let agentToolSchema = ToolArgsSchema(fields: [
    ToolArgField(name: "description", type: .string, required: true),
    ToolArgField(name: "prompt", type: .string, required: true),
    ToolArgField(name: "subagent_type", type: .string, required: false)
])

/// Tool that delegates a task to a specialized subagent.
public struct SubagentTool: Tool {
    public let name = "agent"

    private let subagents: [SubagentDefinition]
    private let parentConfig: CodingAgentConfig
    private let parentSessionId: String

    public init(
        subagents: [SubagentDefinition],
        parentConfig: CodingAgentConfig,
        parentSessionId: String = ""
    ) {
        self.subagents = subagents
        self.parentConfig = parentConfig
        self.parentSessionId = parentSessionId
    }

    public func execute(arguments: String, cwd: String, cancellation: CancellationHandle?) async -> ToolResult {
        let validation = ToolArgsValidator.validate(arguments, schema: agentToolSchema)
        let args: ValidatedArgs
        switch validation {
        case .success(let validated):
            args = validated
        case .failure(let errors):
            return ToolArgsValidator.formatErrors(errors)
        }

        guard args.string("description") != nil else {
            return ToolResult.error(.invalidType, message: "Invalid type for description: expected string", hint: "description: $.description")
        }
        guard let taskPrompt = args.string("prompt") else {
            return ToolResult.error(.invalidType, message: "Invalid type for prompt: expected string", hint: "prompt: $.prompt")
        }

        let subagentType = args.string("subagent_type") ?? "general"
        guard let definition = subagents.first(where: { $0.name == subagentType }) else {
            let available = subagents.map(\.name).joined(separator: ", ")
            return ToolResult.error(
                .unknownTool,
                message: "Unknown subagent type: \(subagentType)",
                hint: "Available: \(available.isEmpty ? "none" : available)"
            )
        }

        do {
            let result = try await runSubagent(
                definition: definition,
                taskPrompt: taskPrompt,
                parentConfig: parentConfig,
                parentSessionId: parentSessionId,
                cancellation: cancellation
            )
            return ToolResult(output: result.text, isError: false)
        } catch is SubagentCancellationError {
            return ToolResult.error(.cancelled, message: "Subagent cancelled")
        } catch {
            return ToolResult.error(.executionFailed, message: "Subagent failed: \(error.localizedDescription)")
        }
    }
}

/// Creates the `agent` tool for delegating tasks to configured subagents.
public func createAgentTool(
    subagents: [SubagentDefinition],
    config: CodingAgentConfig,
    parentSessionId: String = ""
) -> any Tool {
    SubagentTool(
        subagents: subagents,
        parentConfig: config,
        parentSessionId: parentSessionId
    )
}
