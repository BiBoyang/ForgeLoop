# STEP-026：Transcript 语义增强

## 目标
- 作为 UI 收口步骤，统一 transcript 语义与显示策略。
- 提升工具执行与后台通知场景的信息密度与可读性。

## 实现范围
- 涉及模块：`ForgeLoopTUI`、`ForgeLoopCli`
- 涉及文件（建议）：
  - `Sources/ForgeLoopTUI/TranscriptRenderer.swift`
  - `Sources/ForgeLoopCli/AgentEventRenderAdapter.swift`
  - `Tests/ForgeLoopCliTests/TranscriptRendererTests.swift`
  - `Tests/ForgeLoopCliTests/TranscriptRendererToolResultTests.swift`

## 实现要求
- 支持 thinking block 渲染（可区分于普通文本）。
- 避免 toolCall 在 streaming 与 tool execution 区域重复显示。
- 工具结果支持多行预览与可控截断。
- 背景任务通知支持折叠显示，避免 transcript 噪音。
- 明确 `RenderEvent` 与 `AgentEvent` 边界，避免重复转换逻辑继续膨胀。

## 验证方式
- 命令：
  - `swift test --filter TranscriptRendererTests`
  - `swift test --filter TranscriptRendererToolResultTests`
  - `swift test --filter ForgeLoopCliTests`
- 预期结果：
  - streamingRange 覆盖更新稳定；
  - 工具结果渲染清晰且不重复；
  - 通知内容可读、不过度膨胀；
  - 与 `STEP-028A` 基线相比，渲染延迟不出现显著回退。

## 风险与回滚
- 风险：
  - 渲染语义增强与事件适配层边界不清导致重复逻辑。
- 回滚点：
  - 分阶段开关新语义分支，逐项切换并验证。
