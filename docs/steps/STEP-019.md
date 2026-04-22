# STEP-019：工具执行并发策略（sequential/parallel）最小切换

## 目标
- 为 `AgentLoop` 增加可配置工具执行策略：串行/并行。
- 并行模式下仍保证结果回写顺序与 source order 一致。

## 实现范围
- 涉及模块：`ForgeLoopAgent`
- 涉及文件（建议）：
  - `Sources/ForgeLoopAgent/AgentTypes.swift`
  - `Sources/ForgeLoopAgent/AgentLoop.swift`
  - `Sources/ForgeLoopAgent/CodingAgentBuilder.swift`
  - `Tests/ForgeLoopAgentTests/AgentLoopToolExecutionTests.swift`

## 实现要求
- 新增 `ToolExecutionMode`：`.sequential` / `.parallel`。
- `.parallel` 模式使用结构化并发（`TaskGroup`）。
- 事件顺序保持：
  - `toolExecutionStart` 可并行发；
  - `toolExecutionEnd` 和 `tool_result` 注入按原 `toolCall` 顺序收敛。
- 失败不短路：单个工具失败不阻断整轮。

## 验证方式
- 命令：
  - `swift test --filter AgentLoopToolExecution`
  - `swift test --filter Agent`
  - `swift test`
- 预期结果：
  - 两种模式行为可切换；
  - 并行模式不打乱结果顺序。

## 风险与回滚
- 风险：
  - 并行下事件时序更复杂，易出现竞争。
- 回滚点：
  - 默认保持 `.sequential`，并行作为可选开关。
