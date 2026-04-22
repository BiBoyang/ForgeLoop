import Foundation
import ForgeLoopAI

public struct CodingAgentConfig: Sendable {
    public var model: Model
    public var cwd: String
    public var systemPrompt: String?
    public var toolExecutionMode: ToolExecutionMode

    public init(
        model: Model,
        cwd: String,
        systemPrompt: String? = nil,
        toolExecutionMode: ToolExecutionMode = .sequential
    ) {
        self.model = model
        self.cwd = cwd
        self.systemPrompt = systemPrompt
        self.toolExecutionMode = toolExecutionMode
    }
}

public func makeCodingAgent(_ config: CodingAgentConfig) async -> Agent {
    let systemPrompt = config.systemPrompt ?? buildSystemPrompt(cwd: config.cwd)
    let toolExecutor = ToolExecutor()
    toolExecutor.register(ReadTool())
    toolExecutor.register(WriteTool())
    toolExecutor.register(EditTool())
    toolExecutor.register(BashTool())
    toolExecutor.register(ListTool())
    toolExecutor.register(FindTool())
    toolExecutor.register(GrepTool())

    let bgManager = BackgroundTaskManager()
    toolExecutor.register(BgTool(manager: bgManager))
    toolExecutor.register(BgStatusTool(manager: bgManager))

    let agent = Agent(
        initialState: AgentInitialState(
            systemPrompt: systemPrompt,
            model: config.model
        ),
        toolExecutor: toolExecutor,
        cwd: config.cwd
    )
    agent.toolExecutionMode = config.toolExecutionMode
    agent.setupBackgroundNotifications(manager: bgManager)
    return agent
}
