# STEP-023：TUI 渲染内核升级（inline retained-mode）

## 目标
- 明确核心变更：从“绝对定位覆盖终端顶部”迁移到“相对定位的 inline 锚点重绘”。
- 保留 shell 滚动历史，避免当前首帧清屏与顶部覆盖行为。

## 实现范围
- 涉及模块：`ForgeLoopTUI`、`ForgeLoopCli`
- 涉及文件（建议）：
  - `Sources/ForgeLoopTUI/TUI.swift`
  - `Sources/ForgeLoopCli/CodingTUI.swift`
  - `Sources/ForgeLoopCli/TUIRunner.swift`（按需补充终端尺寸/信号处理）
  - `Tests/ForgeLoopCliTests/TUIRunnerTests.swift`（按需扩展）

## 实现要求
- `023A（最小闭环）`
  - 取消首帧 `ESC[2J` 清屏。
  - 常规刷新路径不再使用绝对定位 `ESC[n;1H`。
  - 完成“相对回位 -> 清理旧帧区域 -> 重绘新帧区域”的最小循环。
  - 锁仅保护状态快照，不在锁内执行 stdout I/O。
- `023B（补强）`
  - shrink 场景无残影。
  - 引入物理行预算（考虑终端宽度导致的折行），避免逻辑行/物理行不一致残影。
  - resize 后强制全量区域重绘（而非仅按逻辑行差异重绘）。
  - 引入 cursor marker（或等价机制）保证输入光标定位正确。
  - 处理边界：空帧、单行帧、快速连续刷新、非 TTY 降级。
- ANSI 策略（伪代码，`inlineAnchor`）
  - 首帧：直接在当前光标处输出新帧（不清屏），记录 `lastFramePhysicalRows`。
  - 后续帧：
    - `\r` + `ESC[<lastRows-1>A` 回到旧帧顶部（相对移动）
    - 循环 `lastRows` 次清理：`ESC[2K` + `\r\n`
    - 再次相对回到顶部
    - 输出新帧并更新 `lastFramePhysicalRows`
  - 禁止使用 `ESC[n;1H`（绝对行定位）作为常规路径。
- 回滚机制（必须可执行）
  - 在 `TUI` 内引入 `RenderStrategy`：`.legacyAbsolute` / `.inlineAnchor`。
  - 通过环境变量切换：`FORGELOOP_TUI_STRATEGY=legacy` 可即时降级。
- Go/No-Go 闸门
  - `023A` 未稳定前，不进入 `023B`。
  - 未具备回滚开关前，不切默认策略。

## 验证方式
- 命令：
  - `swift test --filter TUIRunnerTests`
  - `swift test --filter TranscriptRendererTests`
  - `swift test --filter ForgeLoopCliTests`
- 预期结果：
  - shell 历史保留；
  - 常规输出序列不含 `ESC[n;1H`；
  - 首帧不再 `ESC[2J`；
  - shrink/resize 场景无旧帧残留；
  - 量化目标：120 行渲染场景重绘耗时 `p95 < 20ms`（以 `STEP-028A` 基线对比，不回退 >10%）。
- 手工验收（必须）
  - 在 shell 先输出多行历史文本，再启动交互；确认历史文本仍可滚动查看。
  - 在会话中执行多次长/短内容切换与窗口 resize；确认无残影与错位。

## 风险与回滚
- 风险：
  - 相对定位行数计算错误导致闪烁/错位。
  - 折行预算错误导致清理不完整。
- 回滚点：
  - 通过 `FORGELOOP_TUI_STRATEGY=legacy` 切回旧策略；
  - 保留旧实现直到 `023B` 回归通过。
