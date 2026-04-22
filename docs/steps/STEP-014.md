# STEP-014：后台任务与 bg_status 最小闭环

## 目标
- 提供最小后台任务能力：任务登记、状态查询、完成通知注入。
- 与现有前台 `bash` 并存，不影响当前交互路径。

## 实现范围
- 涉及模块：`ForgeLoopAgent`
- 涉及文件（建议）：
  - `Sources/ForgeLoopAgent/BackgroundTaskManager.swift`（新增）
  - `Sources/ForgeLoopAgent/Agent+Background.swift`（新增）
  - `Sources/ForgeLoopAgent/Tooling/BgStatusTool.swift`（新增）
  - `Tests/ForgeLoopAgentTests/BackgroundTaskTests.swift`（新增）

## 实现要求
- 任务模型（最小）：
  - `id`、`command`、`status`（running/success/failed/cancelled）、`startedAt`、`finishedAt`。
- `bg_status` 工具：
  - 支持查询全部任务和指定 `id`。
- 通知桥接：
  - 任务结束时注入 synthetic user message（或专用事件）驱动 `continue()`。
- 顺序约束：
  - 通知投递采用 FIFO，避免乱序回放。

## 验证方式
- 命令：
  - `swift test --filter BackgroundTask`
  - `swift test --filter Agent`
- 预期结果：
  - 后台任务生命周期可追踪；
  - 状态查询可用；
  - 完成通知可触发后续回合。

## 风险与回滚
- 风险：
  - 通知注入与前台 streaming 竞争导致错序。
- 回滚点：
  - busy 时仅入 steering queue，idle 时再触发 `continue()`。
