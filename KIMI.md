# KIMI.md

本文件仅用于 **Kimi Code CLI** 协作约束，规则与 `AGENTS.md` 保持一致并做 Kimi 专属补充。

## 必遵守规则
- 先读：`AGENTS.md` 与 `docs/architecture/ARCHITECTURE.md`。
- 严格遵守分层边界：`ForgeLoopAI` / `ForgeLoopAgent` / `ForgeLoopCli`。
- 严格遵守关键不变量：
  - `messageStart -> messageUpdate* -> messageEnd`
  - `assistant(tool_call) -> tool_result` 顺序不可破坏
  - cancel/abort 不得双终止
- 涉及并发改动时，按 Swift Concurrency 最小安全改动原则执行（结构化并发优先）。
- 对并发相关改动至少跑：
  - `swift test --filter Agent`
  - `swift test --filter AI`
- 大改前先给实现计划；完成后给验证命令与结果摘要。

## 协作节奏
- 计划通过前不开始代码改动。
- 对于多步骤改动，每完成一个关键文件或一个独立验证点后，暂停并给出摘要，等用户确认后再继续。
- 提交/推送前默认给出变更摘要，用户确认后再执行。

## 参考文档
- `docs/architecture/ARCHITECTURE.md`
- `docs/architecture/事件链路.md`
- `docs/adr/ADR-0001-分层与事件驱动.md`
- `docs/reviews/REVIEW-LOG.md`
