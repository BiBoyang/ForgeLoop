# STEP-028：测试与性能门禁

## 目标
- 前置建立“改造前基线”，收口建立 CI 门禁，形成闭环。
- 为 `STEP-023~027` 提供统一的量化验收依据。

## 实现范围
- 涉及模块：`ForgeLoopCli`、`ForgeLoopTUI`、`Tests`
- 涉及文件（建议）：
  - `Tests/ForgeLoopCliTests/*`（新增/补充）
  - 性能基线文档或脚本（按实现需要）
  - `docs/release/RELEASE-CHECKLIST.md`（按需同步）

## 实现要求
- `028A（前置基线）`
  - 在不改业务逻辑的前提下，记录现状基线：渲染耗时、输入延迟、长输出吞吐。
  - 固定最小回归命令集，形成对照快照。
- `028B（收口门禁）`
  - 将关键回归与性能指标纳入 CI。
  - 策略：先 non-blocking 记录趋势，再逐步启用阈值阻断。
- 统一阈值建议
  - 相对 `028A` 基线，关键指标回退超过 10% 触发告警；
  - 告警连续稳定后再升级为阻断阈值。

## 验证方式
- 命令：
  - `swift test --filter ForgeLoopCliTests`
  - `swift test --filter Agent`
  - `swift test --filter AI`
  - `swift test`
- 预期结果：
  - 形成可重复的改造前/后对照；
  - 核心回归稳定通过；
  - 关键性能指标可观测并可门禁。

## 风险与回滚
- 风险：
  - 指标定义不稳定导致噪音告警。
- 回滚点：
  - 性能检查先保持 non-blocking；出现噪音时回退为“仅记录”。
