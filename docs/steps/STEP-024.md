# STEP-024：输入链路重构（raw stdin + keybinding）

## 目标
- 用两阶段方式完成输入链路替换，先稳住核心键位，再扩能力。
- 从 `readLine()` 迁移到 raw stdin 事件流，统一 keybinding 分发。

## 实现范围
- 涉及模块：`ForgeLoopCli`
- 涉及文件（建议）：
  - `Sources/ForgeLoopCli/TUIRunner.swift`
  - `Sources/ForgeLoopCli/CodingTUI.swift`
  - `Tests/ForgeLoopCliTests/TUIRunnerTests.swift`
  - `Tests/ForgeLoopCliTests/PromptControllerTests.swift`（按需补充）

## 实现要求
- `024A（最小闭环）`
  - raw stdin + ESC 序列解析落地。
  - 支持核心键位：Enter / Esc / Ctrl-C。
  - 独立 ESC flush 正常，不与 CSI 序列串扰。
- `024B（补强）`
  - 支持上下键与 bracketed paste。
  - 扩展 keybinding 注册能力，保持行为可测试。
- Go/No-Go 闸门
  - `024A` 达标前，不开启 `024B`。
  - streaming 中输入不丢失，严格沿用 steer 入队语义。

## 验证方式
- 命令：
  - `swift test --filter TUIRunnerTests`
  - `swift test --filter PromptControllerTests`
  - `swift test --filter ForgeLoopCliTests`
- 预期结果：
  - 独立 `Esc` 识别成功率 100%；
  - Esc 与 CSI 不串扰；
  - paste 场景不破坏输入状态；
  - 对比 `STEP-028A` 基线，输入响应不回退 >10%。

## 风险与回滚
- 风险：
  - 不同终端对 escape 序列分片行为不一致。
- 回滚点：
  - 保留最小兼容输入路径作为临时降级开关。
