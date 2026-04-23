# STEP-025：组件化布局落地（Header/Transcript/Status/Queue/Input）

## 目标
- 以“薄布局”策略推进组件化，降低一次性重构成本。
- 将 `CodingTUI` 从“拼 frame”迁移为“组件树 + 布局器”。

## 实现范围
- 涉及模块：`ForgeLoopCli`、`ForgeLoopTUI`
- 涉及文件（建议）：
  - `Sources/ForgeLoopCli/CodingTUI.swift`
  - `Sources/ForgeLoopTUI/TUI.swift`
  - `Sources/ForgeLoopTUI/TranscriptRenderer.swift`
  - 新增布局/组件文件（按实现需要）

## 实现要求
- 第一步只落三块：`Transcript / Status / Input`，先跑通主交互链路。
- 第二步再引入 `Header / Queue / Divider`，完成完整布局区块。
- Transcript 视口预算可随终端高度动态调整。
- 业务层只更新状态，不直接拼最终 frame。
- Go/No-Go 闸门：三块薄布局稳定后再引入完整布局。

## 验证方式
- 命令：
  - `swift test --filter TranscriptRendererTests`
  - `swift test --filter ForgeLoopCliTests`
  - `swift test --filter AgentStabilityTests`
- 预期结果：
  - 主交互路径（输入/渲染/状态）稳定；
  - Transcript 可稳定贴底；
  - 完整布局接入后 Queue 伸缩不破坏输入区。

## 风险与回滚
- 风险：
  - 重构跨度较大，易出现局部刷新错位。
- 回滚点：
  - 分阶段接入组件化；保留旧拼帧路径直到功能对齐并通过回归。
