# STEP-020：TUI 交互增强（/help、工具摘要折叠、状态栏）

## 目标
- 提升 CLI 可用性，降低工具输出密集时的信息噪音。
- 在不破坏事件模型前提下增加轻量交互能力。

## 实现范围
- 涉及模块：`ForgeLoopCli`
- 涉及文件（建议）：
  - `Sources/ForgeLoopCli/PromptController.swift`
  - `Sources/ForgeLoopCli/TranscriptRenderer.swift`
  - `Sources/ForgeLoopCli/TUI.swift`
  - `Tests/ForgeLoopCliTests/SlashCommandsTests.swift`
  - `Tests/ForgeLoopCliTests/TranscriptRendererTests.swift`

## 实现要求
- 新增 `/help`，列出可用 slash 命令。
- 工具结果支持简易折叠显示（最小：截断 + “更多行省略”提示）。
- 状态栏显示：模型、streaming 状态、pending tool 数量（可选最小版）。

## 验证方式
- 命令：
  - `swift test --filter SlashCommands`
  - `swift test --filter TranscriptRenderer`
  - `swift test`
- 预期结果：
  - 命令帮助可用；
  - 工具输出长文本场景可读性提升；
  - 回归通过。

## 风险与回滚
- 风险：
  - 渲染逻辑复杂化导致行替换错位。
- 回滚点：
  - 保留当前稳定渲染路径开关，增强能力可配置关闭。
