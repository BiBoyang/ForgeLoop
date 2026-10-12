---
task: /Users/boyang/Desktop/WebKit_build/ForgeLoop/plans/TASK-sandbox-docs.md
status: done
from: Planner
to: Executor
created: 2026-10-12
---

# 任务：文档同步与移植笔记（TASK-sandbox-docs）

## 目标
同步项目文档（用户可见行为变化 + 架构单一事实源），沉淀 Codex → ForgeLoop 沙箱移植笔记。
成功标准：ARCHITECTURE.md 与实现一致；README 覆盖新行为；移植笔记含映射表与决策记录。

## 涉及文件（绝对路径）
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/docs/architecture/ARCHITECTURE.md`
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/README.md`
- 修改 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/docs/reviews/REVIEW-LOG.md`
- 新建 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/notes/codex-sandbox-porting-notes.md`
- 不改动 Sources/、Tests/、Package.swift

## 验收标准（DoD）
1. ARCHITECTURE.md：新增 ForgeLoopSandbox 层描述（PermissionProfile / 渲染器 / transform 两段式）+ 审批升级链路（启发式 → policy → handler → 重跑一次）；分层边界表更新（ForgeLoopAgent 依赖 ForgeLoopSandbox）
2. README：沙箱默认行为（workspaceWrite(cwd) + 断网）、审批交互（允许一次/拒绝）、ShellCommandAuditor 移除后完整 shell 能力、`CodingAgentConfig.sandboxProfile/approvalPolicy/escalationHandler` 三个配置口子
3. 必须写入的语义注记（Review 移交，一条都不能少）：
   - subagent 沙箱语义：实际是 `override ?? 默认构造`，父 fullAccess 不泄漏给子（fail-closed），非字面透传
   - 已知限制：代码路径 abort 不 resume 挂起的审批 continuation（Esc 已覆盖）
   - 验证边界：网络断网语义端到端验证仅 spike 层证据（本机代理 env 污染，集成测试豁免）
4. REVIEW-LOG.md：补本期四个任务的条目（spike/core/wire/approval + 四份 Review Card 链接）
5. 移植笔记：Codex 概念 → ForgeLoop 实现映射表（PermissionProfile↔SandboxPolicy、transform↔SandboxManager、启发式↔is_likely_sandbox_denied、escalationHandler↔AskForApproval 等）、裁剪点（Guardian/network-proxy/execpolicy 缓做的一句话理由）、firmlink 等踩坑出处（引用 notes/sandbox-spike-report.md）
6. 遵循 AGENTS.md §7：不改写与本次行为无关的既有文档内容

## 上游任务产出
- 四份 Review Card：`/Users/boyang/Desktop/WebKit_build/ForgeLoop/reviews/` 下 `REVIEW-sandbox-spike-2026-10-12.md`、`REVIEW-sandbox-core-2026-10-12.md`、`REVIEW-sandbox-wire-2026-10-12.md`、`REVIEW-sandbox-approval-2026-10-12.md`
- 实现事实源：`Sources/ForgeLoopSandbox/`、`Sources/ForgeLoopAgent/Tooling/BashTool.swift`、`CodingAgentBuilder.swift`、`SubagentRunner.swift`、`Sources/ForgeLoopCli/CodingTUISession.swift`（ApprovalPrompt/SandboxApprovalBridge）

## 硬停止条件（命中任一即停并上报，不硬试、不回滚）
1. 同一处修改尝试超过 3 次仍未通过；
2. 需要改动上述清单之外的文件；
3. 测试/构建失败原因超出本任务描述范围；
4. 认为验收标准或任务范围本身有误、互斥或已过时。

## 只读约束
TASK 文件与本文件整体（含 front matter 状态头）对你只读；状态头由 Owner 维护。
对验收标准有异议时，命中硬停止条件 4，停下上报，不得修改。

## 过程记录
- 每完成一个 step、或命中硬停止条件时，向 `/Users/boyang/Desktop/WebKit_build/ForgeLoop/prompts/TASK-sandbox-docs.status.md` 追加一行：
  `YYYY-MM-DD HH:mm | step N | done/blocked | 证据（命令+结果 / 文件路径） | 下一步`
- 只追加，不修改已有行。中断续跑时，先读该 status 文件再继续干活。
- status 文件为协议约定写入，不计入「涉及文件」清单之外的改动。

## 上报格式
停止或完成时输出：当前状态（done / stopped）、已改动文件列表、关键 diff 摘要、自测命令与结果、已知风险 / 卡点描述，并附 status 文件绝对路径（未写过程记录视为未完成）。
