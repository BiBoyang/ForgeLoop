# STEP-015：Slash Commands（/model /compact）最小实现

## 目标
- 提供最常用命令式交互入口，降低 TUI 操作成本。
- 保持与 Agent 状态一致，不破坏 streaming 行为。

## 实现范围
- 涉及模块：`ForgeLoopCli`、`ForgeLoopAgent`
- 涉及文件（建议）：
  - `Sources/ForgeLoopCli/PromptController.swift`
  - `Sources/ForgeLoopCli/CodingTUI.swift`
  - `Sources/ForgeLoopAgent/AgentState.swift`（如需补 compact 能力）
  - `Tests/ForgeLoopCliTests/SlashCommandsTests.swift`（新增）

## 实现要求
- `/model`：
  - 无参数时显示当前模型；
  - 有参数时切换到目标模型（最小可先做已注册模型集内切换）。
- `/compact`：
  - 压缩历史上下文（最小：保留最近 N 轮 + system prompt）。
- 行为约束：
  - streaming 中收到 slash 命令时不直接中断 run，按现有输入策略处理（可入队或提示）。
  - 命令错误返回明确可见提示，不崩溃。

## 验证方式
- 命令：
  - `swift test --filter SlashCommands`
  - `swift test --filter PromptController`
  - `swift test`
- 预期结果：
  - slash 命令在 idle/streaming 两种状态下行为一致可预期；
  - 回归通过。

## 风险与回滚
- 风险：
  - compact 后上下文丢失关键信息。
- 回滚点：
  - 仅先实现“保留最近 N 轮”并提供可配置 N。
