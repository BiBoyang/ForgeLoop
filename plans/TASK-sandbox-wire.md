# TASK-sandbox-wire：执行链路接入沙箱

- 状态：done
- 依赖：TASK-sandbox-core
- 下游：TASK-sandbox-approval

## 目标
ForgeLoopAgent 的所有命令执行（前台 BashTool、BackgroundTaskManager）统一经过 `SandboxTransform`；删除 `ShellCommandAuditor`，把安全职责移交 OS 沙箱，放开管道/重定向等完整 shell 能力。

## 涉及文件（绝对路径）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Package.swift`（ForgeLoopAgent 依赖 ForgeLoopSandbox）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/Tooling/BashTool.swift`
  - 删除 `ShellCommandAuditor` 及其调用；command 允许任意 shell 文本（经 `/bin/sh -c` 或等价方式执行）
  - 执行前经 SandboxTransform 包装；profile 从新注入的依赖获取
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/Tooling/ProcessRunner.swift`（接受可选 profile 参数或包装后 argv，二选一，以保持调用方简单为准）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/BackgroundTaskManager.swift`（后台任务同样过沙箱，不留裸奔通道）
- profile 的注入路径：由 SessionCoordinator/CodingAgentBuilder 构造时下发默认值（默认 `workspaceWrite(cwd)` + network disabled，对齐 Codex workspace-write 默认断网；提供配置口子可切 `fullAccess`）；涉及 `CodingAgentBuilder.swift`、`SessionCoordinator.swift` 的最小改动
- `PathGuard` 保留不动（文件工具的第二道防线）
- 测试：更新受影响的现有测试 + 新增"带管道命令在沙箱内可执行"的集成测试

## DoD
- `bash` 工具可在默认 profile 下执行 `ls | head` 这类管道命令
- 默认 profile 下写 cwd 成功、写 $HOME 失败（集成测试或手工验证记录）
- background 模式同样被沙箱覆盖（有测试或验证记录）
- `swift test --filter Agent` 全绿，无 auditor 残留引用

## 验证命令
- `swift test --filter Agent`；手工 TUI 冒烟（构造越界写观察拒绝）
