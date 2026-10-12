---
task: /Users/boyang/Desktop/WebKit_build/ForgeLoop/plans/TASK-sandbox-approval.md
status: done
from: Planner
to: Executor
created: 2026-10-12
---

# 任务：拒绝检测与 CLI 审批升级（TASK-sandbox-approval）

## 目标
沙箱执行失败被启发式判定为"沙箱拒绝"时，按 ApprovalPolicy 向用户请求升级，批准后非沙箱重跑一次；拒绝或 policy=never 则按失败回灌模型。**附带 Owner 批准的扩 scope 项**：把主 agent 的 sandbox profile 透传进 subagent，堵 `SubagentRunner` 裸奔通道。
成功标准：三分支（批准→重跑成功 / 拒绝→错误回灌 / never→不问直接败）测试全覆盖；`swift test --filter Agent` 全绿；subagent 的 bash 同样被沙箱覆盖。

## 涉及文件（绝对路径）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopSandbox/`（新增 `SandboxDenialHeuristic`、`ApprovalPolicy`，纯函数/数据，与 PermissionProfile 同层）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/Tooling/BashTool.swift`（升级钩子接入）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/CodingAgentBuilder.swift`（policy 配置口子 + handler 注入）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/SubagentRunner.swift`（**Owner 批准扩 scope**：profile 透传）
- 必要时修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/SubagentTool.swift`（仅 profile 透传链路）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopCli/`（CodingTUISession 相关：审批提示 UI）
- 测试：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/Tests/ForgeLoopSandboxTests/` 与 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Tests/ForgeLoopAgentTests/` 下新增/修改
- REVIEW-LOG / ARCHITECTURE.md / README 不动，留给 TASK-sandbox-docs

## 验收标准（DoD）
1. `ApprovalPolicy`：`never / onFailure` 两档，默认 onFailure，`Codable & Sendable`；挂在 `CodingAgentConfig` 上（与 sandboxProfile 并列）
2. `SandboxDenialHeuristic`：纯函数 (exitCode, stderr) → Bool。**锚点收紧**：非零退出 + stderr 含 `Operation not permitted`（EPERM strerror，跨工具稳定）。curl 的 DNS 失败（exit 6）等网络拒绝**不触发**升级（v1 范围，注释说明）
3. 升级链路：BashTool 注入可选 `escalationHandler`（`@Sendable` 闭包，禁止 MainActor 兜底）；policy=onFailure 且命中启发式 → 调 handler（带命令与原因）；批准 → 以 `fullAccess + network enabled` 等价透传方式**重跑一次，仅一次**；拒绝/handler 缺失 → 原失败结果回灌并附一句话提示
4. CLI 审批 UI：复用 ListPicker 交互形态（对齐 /model picker），展示命令+原因，`允许一次 / 拒绝` 两选项；**阻塞等待用户输入**，不用 footer notice 糊过去；等待期间不破坏 AGENTS.md §4 事件闭环与取消语义（abort 可中断等待）
5. **扩 scope 项**：`SubagentRunner.registerAllowedTools` 链路把主 agent profile 透传进 `BackgroundTaskManager(profile:)` / `BashTool(manager:profile:)`；subagent 的 escalationHandler 为 nil（拒绝即失败，不在 subagent 内交互）
6. 测试：
   - 启发式单测：用 spike 报告 §2.1 真实样本为正例；负例含"exit 1 但无 EPERM 文本""exit 0 含文本""curl exit 6 DNS 文本"
   - 流程测试（注入 fake handler）：批准→重跑成功（真实命令写 $HOME 唯一名文件，事后清理）；拒绝→无重跑、错误回灌；never→handler 不被调用
   - subagent 覆盖：构造 subagent 工具链路验证其 bash 写 $HOME 被拒
   - `swift test --filter Agent` 与 `swift test --filter ForgeLoopSandboxTests` 全绿
7. AppKit 不接（默认 config 下 handler=nil，等价 never，行为安全）

## 上游任务产出
- 拒绝特征第一手数据（必读）：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/notes/sandbox-spike-report.md` §2
- 主 agent profile 注入参考：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopAgent/CodingAgentBuilder.swift`（SandboxProfileFactory / makeCodingAgent）
- subagent 裸奔通道证据：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/reviews/REVIEW-sandbox-wire-2026-10-12.md` Findings [Major]

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围；
4. 认为验收标准或任务范围本身有误、互斥或已过时。

## 只读约束
TASK 文件与本文件整体（含 front matter 状态头）对你只读；状态头由 Owner 维护。
对验收标准有异议时，命中硬停止条件 4，停下上报，不得修改。

## 过程记录
- 每完成一个 step、或命中硬停止条件时，向 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/prompts/TASK-sandbox-approval.status.md` 追加一行：
  `YYYY-MM-DD HH:mm | step N | done/blocked | 证据（命令+结果 / 文件路径） | 下一步`
- 只追加，不修改已有行。中断续跑时，先读该 status 文件再继续干活。
- status 文件为协议约定写入，不计入「涉及文件」清单之外的改动。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述，并附 status 文件绝对路径（未写过程记录视为未完成）。
