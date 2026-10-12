---
task: /Users/boyang/Desktop/WebKit_build/ForgeLoop/plans/TASK-sandbox-wire.md
status: pending
from: Planner
to: Executor
created: 2026-10-12
---

# 任务：执行链路接入沙箱（TASK-sandbox-wire）

## 目标
ForgeLoopAgent 全部命令执行（前台 BashTool + BackgroundTaskManager）统一经 `SandboxTransform` 包装；删除 `ShellCommandAuditor`，放开完整 shell 能力（管道/重定向/复合命令）。
成功标准：`swift test --filter Agent` 全绿；默认 profile 下 `ls | head` 类管道命令可执行、写 cwd 成功、写 $HOME 被拒。

## 涉及文件（绝对路径）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Package.swift`（ForgeLoopAgent target 增加对 ForgeLoopSandbox 的依赖）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/Tooling/BashTool.swift`
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/Tooling/ProcessRunner.swift`
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/BackgroundTaskManager.swift`
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/CodingAgentBuilder.swift`（profile 注入，最小改动）
- 如确有需要：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopCli/SessionCoordinator.swift`（仅 profile 透传，不改交互）
- 修改/新增 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Tests/ForgeLoopAgentTests/` 下相关测试
- REVIEW-LOG / ARCHITECTURE.md / README 本任务**不动**，统一由下游 TASK-sandbox-docs 收尾

## 验收标准（DoD）
1. `ShellCommandAuditor` 及其全部引用删除，无残留；无 `args` 时 command 经 `/bin/sh -c` 执行（完整 shell 能力）；有 `args` 时保持直接 exec
2. `ProcessRunner` 增加可选 `profile: PermissionProfile?` 形参（默认 nil = 不包装，保持其他调用方零改动）；非 nil 且 `SandboxTransform.requiresSandbox` 时内部完成包装——包装复杂度沉在 ProcessRunner，调用方只传 profile
3. BashTool 前台与 background 模式、BackgroundTaskManager 全部从注入点取 profile 并传入 ProcessRunner，不留裸奔通道
4. profile 构造策略（对齐 Codex，且在调用方而非纯函数层完成校验）：
   - 默认 `workspaceWrite(writableRoots: [cwd])` + `network: .disabled`
   - 构造时校验每个 writable root **存在、为目录、非 symlink**（不满足则拒绝该 root 并记录，空列表时降级 readOnly）——这是 Review 移交的策略校验职责
   - 拒绝路径含控制字符（`\n` 等）的 writable root（防 sbpl 注入，Review Minor 移交项）
   - 预留配置口子可切 `fullAccess`（本任务只需代码路径存在，UI/配置文件接线不在范围）
5. 测试：
   - 新增集成测试：沙箱内执行 `printf 'a\nb\n' | head -1`（管道）、写 cwd 文件成功、写 `$HOME` 唯一名文件被拒且目标不存在（用 spike 实测特征：非零退出 + `Operation not permitted`）
   - background 模式同样被沙箱覆盖的测试或验证记录
   - 涉及网络的测试必须先 unset 代理 env（spike 踩坑 2），否则不测网络项
   - 更新因 auditor 删除而失效的既有测试
   - `swift test --filter Agent` 全绿；`swift build` 无新警告
6. 遵循 AGENTS.md §4/§5：不破坏事件闭环与取消语义；不引入 `@MainActor` 兜底或 `Task.detached`

## 上游任务产出
- ForgeLoopSandbox API（已 Approved）：`PermissionProfile` / `SeatbeltProfileRenderer` / `SandboxTransform.wrap(command:arguments:profile:)` / `requiresSandbox` / `SandboxSupport.ensureSupported`（源码 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopSandbox/`）
- 拒绝特征与踩坑（必读）：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/notes/sandbox-spike-report.md` §2 §4
- Review 移交项：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/reviews/REVIEW-sandbox-core-2026-10-12.md` Findings（已并入上文 DoD 4）

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围；
4. 认为验收标准或任务范围本身有误、互斥或已过时。

## 只读约束
TASK 文件与本文件整体（含 front matter 状态头）对你只读；状态头由 Owner 维护。
对验收标准有异议时，命中硬停止条件 4，停下上报，不得修改。

## 过程记录
- 每完成一个 step、或命中硬停止条件时，向 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/prompts/TASK-sandbox-wire.status.md` 追加一行：
  `YYYY-MM-DD HH:mm | step N | done/blocked | 证据（命令+结果 / 文件路径） | 下一步`
- 只追加，不修改已有行。中断续跑时，先读该 status 文件再继续干活。
- status 文件为协议约定写入，不计入「涉及文件」清单之外的改动。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述，并附 status 文件绝对路径（未写过程记录视为未完成）。
