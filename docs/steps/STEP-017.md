# STEP-017：后台任务可取消与进程回收完善

## 目标
- 将当前 `BackgroundTaskManager.cancel` 从“仅改状态”升级为“真实终止进程 + 状态一致”。
- 保证后台任务取消语义与前台 `abort` 保持一致。

## 实现范围
- 涉及模块：`ForgeLoopAgent`
- 涉及文件（建议）：
  - `Sources/ForgeLoopAgent/BackgroundTaskManager.swift`
  - `Sources/ForgeLoopAgent/Tooling/BgTool.swift`
  - `Sources/ForgeLoopAgent/Tooling/BgStatusTool.swift`
  - `Sources/ForgeLoopAgent/Tooling/ProcessRunner.swift`
  - `Tests/ForgeLoopAgentTests/BackgroundTaskTests.swift`

## 实现要求
- 为后台任务保存可取消句柄（进程句柄或 cancellation token）。
- `cancel(id)` 必须尝试终止对应进程并更新状态为 `cancelled`。
- 完成回调只触发一次，避免 `cancelled -> failed/success` 反复覆盖。
- `bg_status` 输出中增加取消来源信息（主动取消/外部终止可选）。

## 验证方式
- 命令：
  - `swift test --filter BackgroundTask`
  - `swift test --filter Agent`
- 预期结果：
  - 取消后进程不再运行；
  - 状态稳定为 `cancelled`；
  - 通知链路无重复注入。

## 风险与回滚
- 风险：
  - 状态机竞争导致偶发错序。
- 回滚点：
  - 先保留单线程状态提交通道（actor 内统一写入）。
