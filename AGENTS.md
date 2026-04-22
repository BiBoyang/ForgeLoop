# AGENTS.md

适用范围：本文件所在目录及全部子目录（即整个仓库）。

## 1) 目标与协作方式
- 本项目目标：复刻 KWWK 的核心行为，优先保证事件语义一致与并发安全。
- 开发默认采用“小步快跑 + 可回归验证”。
- 对于已在 `docs/steps/` 定义的任务，严格按任务单实现，不擅自扩 scope。

## 2) 架构单一事实源
- 架构说明统一以 `docs/architecture/ARCHITECTURE.md` 为准。
- 历史背景与决策参考：
  - `docs/architecture/事件链路.md`
  - `docs/adr/ADR-0001-分层与事件驱动.md`
- 若实现与架构冲突，先修正实现，不要“改文档迁就代码”。

## 3) 分层边界（必须遵守）
- `ForgeLoopAI`：Provider、SSE、消息模型、HTTP 抽象。
- `ForgeLoopAgent`：生命周期、回合循环、工具执行、取消与队列。
- `ForgeLoopCli`：输入/渲染/事件消费（只消费 `AgentEvent`，不改 Agent 状态）。
- 禁止跨层直接耦合（例如 CLI 直接操作 Provider 内部状态）。

## 4) 关键行为不变量
- 每次 assistant 回复必须闭环：`messageStart -> messageUpdate* -> messageEnd`。
- 工具顺序必须成立：`assistant(tool_call)` 先入上下文，再执行工具，再注入 `tool_result`。
- `abort/cancel` 后不得出现双终止（例如 `.error` 后又 `.done`）。
- 只允许单个 active run，避免并发重入。

## 5) Swift 并发规则（硬约束）
- 涉及并发改动时，必须遵循 `swift-concurrency` 技能规范（Fast Path + Guardrails）。
- 优先结构化并发（`async/await`、`TaskGroup`、actor），避免无理由 `Task.detached`。
- 不允许用“加 `@MainActor`”做兜底修复，必须说明隔离边界为何正确。
- 长任务必须可取消，并在循环/等待点检查取消状态。
- `@unchecked Sendable` / `nonisolated(unsafe)` 仅在必要时使用，并写明安全不变量。

## 6) 代码与测试要求
- 修复根因，不做表面补丁；保持改动聚焦、最小化。
- 新增行为必须补测试；并发/取消语义必须有对应测试。
- 并发相关改动至少运行：
  - `swift test --filter Agent`
  - `swift test --filter AI`
- 提交前建议运行：`swift test`。

## 7) 文档同步要求
- 当用户可见行为变化时，同步更新：
  - `docs/03-Step看板.md`
  - `docs/reviews/REVIEW-LOG.md`
  - 必要时 `README.md`
- 不变化行为时，不做无意义文档改写。

