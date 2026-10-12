---
task: /Users/boyang/Desktop/WebKit_build/ForgeLoop/plans/TASK-approval-streaming-render.md
status: done
from: Planner
to: Executor
created: 2026-10-12
---

# 任务：审批 picker 在流式期间可见可交互（TASK-approval-streaming-render）

## 目标
修复"审批 picker 在 agent run 进行中不可见"的渲染缺口。
成功标准：streaming 期间 picker 可见可交互，审批结束流式渲染无缝恢复；`swift test --filter Cli` 全绿。

## 背景（必读，全部一手实证）
- 沙箱审批链路本身已实测打通（trace 日志 `sandbox_approval.request` 触发），但 picker 不可见：
  `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopCli/CodingTUISession+Render.swift` 的 `renderFrame` 在 `agent.state.isStreaming == true` 时走 transcript append 增量模式并 **early-return**（约 152 行），footer（picker 所在区域）被跳过
- 输入路由没问题：`CodingTUI.swift` 的 eventLoop 无条件调 `handleResolvedKey`，审批分支在最前面
- 审批 UI 组件：`CodingTUISession.swift` 的 `requestSandboxApproval` + `ApprovalPrompt`；渲染分支在 `CodingTUISession+Render.swift` 的 `makeFooterRenderState`（approval 分支在最前）
- append 模式状态：`appendModeActive` / `transcriptAppendState`（同文件），退出/重入时要保证 transcript 不丢行不重印
- 探针日志 `sandbox_approval.request/resolved`（CodingTUISession.swift）保留，不要删

## 涉及文件（绝对路径）
- `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopCli/CodingTUISession+Render.swift`
- 必要时 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Sources/ForgeLoopCli/CodingTUI.swift`、`CodingTUISession.swift`
- `/Users/boyang/Desktop/WebKit_build/ForgeLoop/Tests/ForgeLoopCliTests/`

## 验收标准（DoD）
1. streaming + activeApproval 非空 → 渲染含 picker 的帧（不 early-return 丢弃 footer）；按键有即时视觉反馈
2. 审批结束 → append 模式正确退出/重入，transcript 不丢行、不重印
3. 非 streaming 审批渲染行为不变
4. 新增测试：streaming 中 activeApproval 设置后产出的帧包含 picker 内容（可加 seam，如直接测 makeFooterRenderState/帧构建层）
5. `swift test --filter Cli` 全绿；`swift build` 无新警告
6. 遵循 AGENTS.md §4/§5

## 上游任务产出
- 真机事故报告（本任务起因）：trace 中 `sandbox_approval.request` 有、无 resolved，picker 不可见，按键无视觉反馈

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围；
4. 认为验收标准或任务范围本身有误、互斥或已过时。

## 只读约束
TASK 文件与本文件整体（含 front matter 状态头）对你只读；状态头由 Owner 维护。
对验收标准有异议时，命中硬停止条件 4，停下上报，不得修改。

## 过程记录
- 每完成一个 step、或命中硬停止条件时，向 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/prompts/TASK-approval-streaming-render.status.md` 追加一行：
  `YYYY-MM-DD HH:mm | step N | done/blocked | 证据（命令+结果 / 文件路径） | 下一步`
- 只追加，不修改已有行。中断续跑时，先读该 status 文件再继续干活。
- status 文件为协议约定写入，不计入「涉及文件」清单之外的改动。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述，并附 status 文件绝对路径（未写过程记录视为未完成）。
