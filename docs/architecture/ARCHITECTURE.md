# ARCHITECTURE

本文档是项目架构与关键不变量的单一事实源（SSOT）。

## 1) 分层职责

### ForgeLoopAI
- Provider 抽象与注册：`APIProvider`、`APIRegistry`
- 流式协议与解析：`AssistantMessageStream`、`SSEParser`
- 消息模型：`Message`、`AssistantMessageEvent`、`ToolCall`、`ToolResultMessage`
- 网络抽象：`HTTPClient`

### ForgeLoopAgent
- 生命周期与状态：`Agent`、`AgentState`
- 回合推进：`AgentLoop`
- 事件总线：`AgentEvent`
- 工具执行：`ToolExecutor`、`Read/Write/Bash` 等
- 队列与取消：`PendingMessageQueue`、`CancellationHandle`

### ForgeLoopCli
- 输入与命令路由：`PromptController`、`CodingTUI`
- 渲染与刷新：`TranscriptRenderer`、`TUI`
- 原则：只消费 `AgentEvent`，不直接写 Agent 内部状态

## 2) 核心事件链路
- Provider SSE
- -> `AssistantMessageEvent`
- -> `AgentEvent.messageUpdate`
- -> `TranscriptRenderer.apply`
- -> `TUI.requestRender`

该链路中的 UI 侧行为必须“可重放、可覆盖、无副作用”。

## 3) 工具闭环语义（关键）
- assistant 产出 `tool_call`
- `AgentLoop` 先将 assistant 消息 append 到上下文
- 发出 `toolExecutionStart`
- 执行工具并得到 `ToolResult`
- 发出 `toolExecutionEnd`
- 注入 `Message.tool(ToolResultMessage)` 到上下文
- 若存在 `tool_result`，继续下一轮模型请求；否则收敛结束

## 4) 全局不变量
- 每条 assistant 回复事件闭环：
  - `messageStart -> messageUpdate* -> messageEnd`
- 终止语义一致：
  - 正常：`.done` + `end(final)`
  - 失败：`.error` + `end(errorMessage)`
  - 取消：`.error(reason: .aborted)` + `end(abortedMessage)` 且不再 `.done`
- 单次只允许一个 active run（防重入）。

## 5) 并发模型与约束（Swift 6）
- 默认优先：结构化并发（`async/await`、`TaskGroup`、actor）。
- UI 相关状态使用 `@MainActor`，非 UI 逻辑禁止滥用 `@MainActor`。
- 长耗时流程必须支持取消并及时响应取消。
- 如需 `@unchecked Sendable`，必须说明安全不变量：
  - 所有可变共享状态是否由锁或 actor 严格保护；
  - 生命周期是否有明确边界；
  - 是否存在跨线程逃逸引用。

## 6) 扩展规则
- 新增 provider：
  - 必须对齐现有 `AssistantMessageEvent` 语义。
- 新增 tool：
  - 必须通过 `ToolExecutor` 统一接入；
  - 必须产出可注入的 `ToolResultMessage`；
  - 必须提供错误语义与最小测试覆盖。
- 新增 UI 渲染行为：
  - 不可破坏 streaming 覆盖替换；
  - tool block 必须可定位替换，避免重复 append。

