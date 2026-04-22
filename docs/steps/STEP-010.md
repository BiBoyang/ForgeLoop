# STEP-010：TUI 工具结果渲染与一致性回归

## 目标
- 将工具执行结果在 transcript 中从“占位文案”升级为“可读摘要”。
- 确保 message streaming 与 tool block 混排时无错位、无残留。

## 实现范围
- 涉及模块：`ForgeLoopCli`
- 涉及文件（建议）：
  - `Sources/ForgeLoopCli/TranscriptRenderer.swift`
  - `Sources/ForgeLoopCli/CodingTUI.swift`（如需补事件映射）
  - `Tests/ForgeLoopCliTests/TranscriptRendererToolResultTests.swift`（新增）

## 实现要求
- `toolExecutionStart`：
  - 仍显示 `● tool(args)` + `⎿ running...`
- `toolExecutionEnd`：
  - 将 running 行替换为：
    - 成功：`⎿ done: <summary>`
    - 失败：`⎿ failed: <summary>`
  - summary 需截断（建议 1 行 + 80 字符）。
- 一致性要求：
  - 多工具并发占位（即便顺序执行也要支持多 pending）替换不串行错位；
  - assistant streaming 结束后 `streamingRange` 清空；
  - 工具结果行不会在下一次重绘中重复 append。

## 验证方式
- 命令：
  - `swift test --filter TranscriptRenderer`
  - `swift test --filter PromptController`
  - `swift test`
- 预期结果：
  - tool block 可读性明显提升；
  - 全量回归绿。

## 风险与回滚
- 风险：
  - 摘要截断策略处理多行输出时格式不稳定。
- 回滚点：
  - 保留旧格式开关，必要时降级为固定文案。
