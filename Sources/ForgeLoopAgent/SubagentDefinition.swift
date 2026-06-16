import Foundation

/// Defines a specialized subagent that can be invoked via the `agent` tool.
public struct SubagentDefinition: Sendable {
    public let name: String
    public let description: String
    public let prompt: String
    public let tools: SubagentTools

    public init(
        name: String,
        description: String,
        prompt: String,
        tools: SubagentTools
    ) {
        self.name = name
        self.description = description
        self.prompt = prompt
        self.tools = tools
    }
}

/// Specifies which tools a subagent is allowed to use.
public enum SubagentTools: Sendable {
    /// All tools available to a coding agent.
    case all
    /// Read-only tools: read, find, grep, list.
    case readOnly
    /// A specific list of tool names.
    case custom([String])
}

extension SubagentDefinition {
    /// General-purpose subagent for any task.
    public static let general = SubagentDefinition(
        name: "general",
        description: "General-purpose subagent for any task",
        prompt: "You are a helpful assistant. Complete the given task.",
        tools: .all
    )

    /// Fast read-only search agent for locating code.
    public static let explore = SubagentDefinition(
        name: "Explore",
        description: "Fast read-only search agent for locating code",
        prompt: "You are a code explorer. Search and read files to answer questions. Do NOT edit files.",
        tools: .readOnly
    )

    /// Software architect for designing implementation plans.
    public static let plan = SubagentDefinition(
        name: "Plan",
        description: "Software architect for designing implementation plans",
        prompt: "You are a software architect. Plan the implementation, consider trade-offs, do NOT edit files.",
        tools: .readOnly
    )
}
