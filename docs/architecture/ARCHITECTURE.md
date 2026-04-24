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

## 2) ForgeLoopTUI 内部边界（Core / Adapter）

`ForgeLoopTUI` 在 target 内逻辑上分为两层（参见 `docs/architecture/TUI-深度优化-RFC.md` §3.1）：

- **TUICore**：通用渲染核心，不依赖任何业务模块。
  - 事件模型：`CoreRenderEvent`（去 chat 语义，见 `Sources/ForgeLoopTUI/CoreRenderEvents.swift`）
  - 渲染器：`TranscriptRenderer.applyCore(_:)` 为核心入口
  - 增量规划：`StreamingTranscriptAppendState` 负责 transcript append-only streaming 的稳定增量规划
  - 原则：Core 不依赖 `ForgeLoopAI` / `ForgeLoopAgent` / `ForgeLoopCli`
- **TUIChatAdapter**：业务语义适配层。
  - `AgentEvent -> CoreRenderEvent` 映射：`Sources/ForgeLoopCli/AgentEventRenderAdapter.swift`
  - `RenderEvent -> CoreRenderEvent` 兼容映射：`Sources/ForgeLoopTUI/RenderEvents.swift` 中的 `LegacyRenderEventAdapter`
  - 旧 `RenderEvent` / `RenderMessage` 已标记 `@available(*, deprecated)`，保留向后兼容

关键不变量：
- 同一语义输入序列下，旧入口 `apply(_:)` 与新入口 `applyCore(_:)` 的输出行完全一致（由 `CoreRenderEventAdapterTests` 保证）。
- `TranscriptRenderer` 当前仅支持 **单个 active block**（`blockStart` 会覆盖之前的 streaming range），`block id` 参数保留用于未来多 block 扩展。

### RenderLoop 调度约束

`RenderLoop`（`Sources/ForgeLoopTUI/RenderLoop.swift`）提供统一帧调度：
- **16ms tick 合帧**：`submit(.normal)` 在 tick 内多次提交只保留最后一帧（latest-frame-wins）。
- **即时刷新**：`submit(.immediate)` 立即 flush 当前 pending frame，不等待 tick。
- **默认开启**：通过环境变量 `FORGELOOP_TUI_RENDER_LOOP=0` 可关闭并回退直出路径。
- **生命周期**：`stop()` 取消 timer 并丢弃 pending frame，退出前必须调用以避免泄漏。

### Inline 渲染增量约束

`TUI` 的 `inlineAnchor` 路径（`Sources/ForgeLoopTUI/TUI.swift`）采用“脏尾段重绘”策略：
- 通过 `firstDifferenceIndex` 找到首个变更行，仅重绘变更尾段（含 1 行上下文），避免全帧清理。
- 同帧重复渲染（内容不变且锚点模式不变）不再输出 ANSI 序列，降低高频流式输出噪声。
- 当锚点模式变化（`cursorOffset` 从 `nil` 到非 `nil` 或反向）时退化为全帧重绘，保证光标语义正确。
- 当当前帧或上一帧物理行数超过终端可视高度时，禁止继续使用 inline 回卷重绘；自动退化为安全的全帧重绘，避免对 scrollback 以上区域做错误覆盖。
- `CodingTUI` 在 **TTY + streaming** 场景下不再走 retained-mode 覆盖式重绘，而是直接追加完整 frame 到 stdout，让终端自然保留 scrollback；streaming 结束后再恢复 inline 输入渲染。
- 为避免整帧追加导致 header / prompt / status 重复刷屏，TTY + streaming 的最终策略收敛为：仅追加 transcript 的稳定增量（新静态行 + 已完成的 assistant 行）；footer（queue/status/input）在 idle 时单独渲染。

### Markdown 增量渲染约束

`ForgeLoopTUI` 引入 `MarkdownEngine` 协议（`Sources/ForgeLoopTUI/MarkdownEngine.swift`）：
- 默认实现 `StreamingMarkdownEngine`：维护单调递增 stable boundary，仅重渲染 unstable tail。
- 未闭合表格在 streaming 阶段降级为纯文本；`isFinal=true` 时收敛为结构化表格渲染。
- 可回退实现 `PlainTextMarkdownEngine`：保留历史按行渲染行为（不做 Markdown 结构化）。

## 3) 核心事件链路
- Provider SSE
- -> `AssistantMessageEvent`
- -> `AgentEvent.messageUpdate`
- -> `TranscriptRenderer.apply`（兼容层）或 `TranscriptRenderer.applyCore`（新入口）
- -> `TUI.requestRender`

该链路中的 UI 侧行为必须「可重放、可覆盖、无副作用」。

## 4) 工具闭环语义（关键）
- assistant 产出 `tool_call`
- `AgentLoop` 先将 assistant 消息 append 到上下文
- 发出 `toolExecutionStart`
- 执行工具并得到 `ToolResult`
- 发出 `toolExecutionEnd`
- 注入 `Message.tool(ToolResultMessage)` 到上下文
- 若存在 `tool_result`，继续下一轮模型请求；否则收敛结束

## 5) 全局不变量
- 每条 assistant 回复事件闭环：
  - `messageStart -> messageUpdate* -> messageEnd`（旧）
  - 等价于 `blockStart -> blockUpdate* -> blockEnd`（新）
- 终止语义一致：
  - 正常：`.done` + `end(final)`
  - 失败：`.error` + `end(errorMessage)`
  - 取消：`.error(reason: .aborted)` + `end(abortedMessage)` 且不再 `.done`
- 单次只允许一个 active run（防重入）。

## 6) 并发模型与约束（Swift 6）
- 默认优先：结构化并发（`async/await`、`TaskGroup`、actor）。
- UI 相关状态使用 `@MainActor`，非 UI 逻辑禁止滥用 `@MainActor`。
- 长耗时流程必须支持取消并及时响应取消。
- 如需 `@unchecked Sendable`，必须说明安全不变量：
  - 所有可变共享状态是否由锁或 actor 严格保护；
  - 生命周期是否有明确边界；
  - 是否存在跨线程逃逸引用。

## 7) 扩展规则
- 新增 provider：
  - 必须对齐现有 `AssistantMessageEvent` 语义。
- 新增 tool：
  - 必须通过 `ToolExecutor` 统一接入；
  - 必须产出可注入的 `ToolResultMessage`；
  - 必须提供错误语义与最小测试覆盖。
- 新增 UI 渲染行为：
  - 不可破坏 streaming 覆盖替换；
  - tool block 必须可定位替换，避免重复 append。
