import Foundation
import ForgeLoopAI
import ForgeLoopDiagnostics

let agentToolSchema = ToolArgsSchema(fields: [
    ToolArgField(name: "description", type: .string, required: true),
    ToolArgField(name: "prompt", type: .string, required: true),
    ToolArgField(name: "subagent_type", type: .string, required: false)
])

/// Tool that delegates a task to a specialized subagent.
public struct SubagentTool: Tool {
    public let name = "agent"

    /// 描述与 subagent_type 的 enum 随当前可用 subagent 列表动态生成，
    /// 让模型只看到真实可选的类型。
    public var definition: ToolDefinition {
        let available = subagents.map(\.name)
        var description = "Delegate a self-contained task to a subagent and return its final text report. The subagent runs independently with its own tool set and cannot ask follow-up questions—make `prompt` complete and specific."
        if !available.isEmpty {
            description += " Available subagent_type values: \(available.joined(separator: ", ")) (default: general)."
        }
        var schema = agentToolSchema.jsonSchema()
        if !available.isEmpty,
           var properties = schema["properties"] as? [String: Any],
           var subagentType = properties["subagent_type"] as? [String: Any] {
            subagentType["enum"] = available
            properties["subagent_type"] = subagentType
            schema["properties"] = properties
        }
        if let definition = try? ToolDefinition(name: name, description: description, parameters: schema) {
            return definition
        }
        return ToolDefinition.make(name: name, description: description, argsSchema: agentToolSchema)
    }

    private let subagents: [SubagentDefinition]
    private let parentConfig: CodingAgentConfig
    private let parentSessionId: String
    private let diagnostics: Diagnostics
    private let parentTraceContext: TraceContext?

    public init(
        subagents: [SubagentDefinition],
        parentConfig: CodingAgentConfig,
        parentSessionId: String = "",
        diagnostics: Diagnostics = Diagnostics(),
        parentTraceContext: TraceContext? = nil
    ) {
        self.subagents = subagents
        self.parentConfig = parentConfig
        self.parentSessionId = parentSessionId
        self.diagnostics = diagnostics
        self.parentTraceContext = parentTraceContext
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
            let parentTraceContext = TraceContextStorage.current ?? self.parentTraceContext
            let result = try await runSubagent(
                definition: definition,
                taskPrompt: taskPrompt,
                parentConfig: parentConfig,
                parentSessionId: parentSessionId,
                parentTraceContext: parentTraceContext,
                diagnostics: diagnostics,
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
    parentSessionId: String = "",
    parentTraceContext: TraceContext? = nil,
    diagnostics: Diagnostics = Diagnostics()
) -> any Tool {
    SubagentTool(
        subagents: subagents,
        parentConfig: config,
        parentSessionId: parentSessionId,
        diagnostics: diagnostics,
        parentTraceContext: parentTraceContext
    )
}
