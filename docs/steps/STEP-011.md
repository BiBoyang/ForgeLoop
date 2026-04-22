# STEP-011：AgentEvent 增强：tool 结果摘要透传

## 目标
- 为 `STEP-010` 提供结构化 tool 结果摘要，避免 CLI 只能显示占位文案。
- 保持工具事件顺序不变，仅增强 `toolExecutionEnd` 负载。

## 实现范围
- 涉及模块：`ForgeLoopAgent`、`ForgeLoopCli`
- 涉及文件（建议）：
  - `Sources/ForgeLoopAgent/AgentTypes.swift`
  - `Sources/ForgeLoopAgent/AgentLoop.swift`
  - `Sources/ForgeLoopCli/TranscriptRenderer.swift`
  - `Tests/ForgeLoopAgentTests/AgentLoopToolExecutionTests.swift`
  - `Tests/ForgeLoopCliTests/TranscriptRendererTests.swift`

## 实现要求
- `toolExecutionEnd` 增加 `summary` 字段（字符串，允许为空）。
- `summary` 生成规则（最小）：
  - 用 `ToolResult.output` 第一行作为摘要源；
  - 超过 80 字符截断并追加 `...`；
  - 空输出显示 `(no output)`。
- 事件顺序不变：
  - `messageEnd(assistant)` -> `toolExecutionStart` -> `toolExecutionEnd` -> `messageEnd(tool)` -> `turnEnd`。
- 兼容旧路径：
  - 未提供摘要时，CLI 退化显示旧文案，不崩溃。

## 验证方式
- 命令：
  - `swift test --filter AgentLoopToolExecution`
  - `swift test --filter TranscriptRenderer`
  - `swift test --filter Agent`
- 预期结果：
  - `toolExecutionEnd` 可携带摘要；
  - TUI 可展示 `done/failed + summary`。

## 风险与回滚
- 风险：
  - 事件签名变化引发编译面变更。
- 回滚点：
  - `summary` 保持可选字段，默认 `nil` 回退旧渲染。
