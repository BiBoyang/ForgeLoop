import Foundation
import ForgeLoopAI

public struct CodingAgentConfig: Sendable {
    public var model: Model
    public var cwd: String
    public var systemPrompt: String?
    public var toolExecutionMode: ToolExecutionMode
    public var subagents: [SubagentDefinition]
    public var streamFn: StreamFn?

    public init(
        model: Model,
        cwd: String,
        systemPrompt: String? = nil,
        toolExecutionMode: ToolExecutionMode = .sequential,
        subagents: [SubagentDefinition] = [],
        streamFn: StreamFn? = nil
    ) {
        self.model = model
        self.cwd = cwd
        self.systemPrompt = systemPrompt
        self.toolExecutionMode = toolExecutionMode
        self.subagents = subagents
        self.streamFn = streamFn
    }
}

public func makeCodingAgent(_ config: CodingAgentConfig) async -> Agent {
    let systemPrompt = config.systemPrompt ?? buildSystemPrompt(cwd: config.cwd)
    let toolExecutor = ToolExecutor()
    toolExecutor.register(ReadTool())
    toolExecutor.register(WriteTool())
    toolExecutor.register(EditTool())
    toolExecutor.register(ListTool())
    toolExecutor.register(FindTool())
    toolExecutor.register(GrepTool())

    let bgManager = BackgroundTaskManager()
    toolExecutor.register(BashTool(manager: bgManager))
    toolExecutor.register(BgTool(manager: bgManager))
    toolExecutor.register(BgStatusTool(manager: bgManager))

    let agent = Agent(
        initialState: AgentInitialState(
            systemPrompt: systemPrompt,
            model: config.model
        ),
        streamFn: config.streamFn,
        toolExecutor: toolExecutor,
        cwd: config.cwd
    )
    agent.toolExecutionMode = config.toolExecutionMode
    agent.backgroundTaskManager = bgManager
    agent.setupBackgroundNotifications(manager: bgManager)

    if !config.subagents.isEmpty {
        let agentTool = createAgentTool(
            subagents: config.subagents,
            config: config,
            parentSessionId: ""
        )
        toolExecutor.register(agentTool)
    }

    return agent
}
