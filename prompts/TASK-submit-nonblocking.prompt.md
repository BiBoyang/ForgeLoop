---
task: /Users/boyang/Desktop/WebKit_build/ForgeLoop/plans/TASK-submit-nonblocking.md
status: done
from: Planner
to: Executor
created: 2026-10-12
---

# 任务：提交不阻塞事件循环（TASK-submit-nonblocking）

## 目标
`SessionCoordinator.submit` 的非 streaming 分支 spawn 后台任务执行 run 并立即返回；run 期间键盘事件正常分发。
成功标准：慢 run 期间 submit 立即返回有测试锁定；审批 picker 在 run 中可操作（真机验收前置）；Cli/Agent 测试全绿。

## 背景（必读，全部一手实证）
- 结构性根因：TUI `eventLoop`（`Sources/ForgeLoopCli/CodingTUI.swift`）逐个 await `handleResolvedKey`；submit 链路 `handleResolvedKey → PromptController.submit → SessionCoordinator.submit → agent.prompt → runLifecycle` 中 `Agent.swift` 的 `try await executor(...)` 会等整个 run 结束——**run 期间事件循环被占死，按键积压**
- 直接症状：沙箱审批 picker 渲染已修（上一任务）但无法操作；Esc abort、steer/queue 在 run 期间同样失灵
- Owner 已拍板方案 B：在 `SessionCoordinator.submit`（`Sources/ForgeLoopCli/SessionCoordinator.swift`）的非 streaming 分支 spawn 后台 `Task` 执行 `agent.prompt`，立即返回 `.submitted`
- 注意语义变化：run 错误不再经 throw 上抛，需确认错误经 agent 事件流可见（`runLifecycle` 内部已有 failure 事件路径）；SubmitResult 全部调用点（CLI/AppKit/eval）逐一核对无退化
- streaming 中的提交走 steer 路径（`agent.state.isStreaming` 分支），本已是立即返回，不动

## 涉及文件（绝对路径）
- `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopCli/SessionCoordinator.swift`
- 必要时 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopCli/PromptController.swift`、`CodingTUISession+Input.swift`
- `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Tests/ForgeLoopCliTests/`

## 验收标准（DoD）
1. 非 streaming 提交立即返回；slash 命令同步语义不变
2. 新增测试：用挂起的假 streamFn 制造长 run，断言 submit 在 run 结束前返回；断言 run 期间第二次提交走 steer 分支
3. run 启动失败有可见反馈路径，不静默
4. Esc 中断路径（现有 `isAbortRequested`/cancel 逻辑）在事件循环解放后实际可用——有测试或明确的手工验证记录
5. `swift test --filter Cli`、`swift test --filter Agent` 全绿；`swift build` 无新警告
6. AGENTS.md §4/§5：单 active run、事件闭环、结构化并发（spawn 的 Task 要有生命周期归属，不用无理由 detached）

## 上游任务产出
- 事故链证据：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/sessions/SESSION-2026-10-12.md`（18:55 与 20:34 段）
- 审批 overlay 渲染（上一任务，已 Approved）：`Sources/ForgeLoopCli/CodingTUISession+Render.swift` 的 `planStreamingApprovalRender`

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围；
4. 认为验收标准或任务范围本身有误、互斥或已过时。

## 只读约束
TASK 文件与本文件整体（含 front matter 状态头）对你只读；状态头由 Owner 维护。
对验收标准有异议时，命中硬停止条件 4，停下上报，不得修改。

## 过程记录
- 每完成一个 step、或命中硬停止条件时，向 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/prompts/TASK-submit-nonblocking.status.md` 追加一行：
  `YYYY-MM-DD HH:mm | step N | done/blocked | 证据（命令+结果 / 文件路径） | 下一步`
- 只追加，不修改已有行。中断续跑时，先读该 status 文件再继续干活。
- status 文件为协议约定写入，不计入「涉及文件」清单之外的改动。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述，并附 status 文件绝对路径（未写过程记录视为未完成）。
