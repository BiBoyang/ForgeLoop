# CLAUDE.md

本文件用于 Claude Code 协作约束，规则与 `AGENTS.md` 保持一致。

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

## 参考文档
- `docs/architecture/ARCHITECTURE.md`
- `docs/architecture/事件链路.md`
- `docs/adr/ADR-0001-分层与事件驱动.md`
- `docs/03-Step看板.md`
- `docs/reviews/REVIEW-LOG.md`

