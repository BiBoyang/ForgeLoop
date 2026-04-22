# STEP-016：发布前稳定性收尾（并发/取消/回归）

## 目标
- 对当前 `STEP-010~015` 新能力做一次“发布前稳定性收尾”。
- 聚焦并发与取消边界，降低后续集成回归风险。

## 实现范围
- 涉及模块：`ForgeLoopAgent`、`ForgeLoopCli`、`ForgeLoopAI`
- 涉及文件（建议）：
  - `Tests/ForgeLoopAgentTests/*`（补并发/取消压力测试）
  - `Tests/ForgeLoopCliTests/*`（补 streaming + tool + slash 混排场景）
  - `Tests/ForgeLoopAITests/*`（补 tool_result 上下文映射边界）
  - `docs/reviews/REVIEW-LOG.md`（记录稳定性结论）

## 实现要求
- 并发与取消（必须）：
  - 覆盖 `bg` 通知注入与前台 streaming 竞争场景；
  - 覆盖 `abort` 与 tool 执行重叠场景（确保无双终止）；
  - 覆盖 slash 命令与队列消息交错场景。
- 稳定性（必须）：
  - 增加至少 1 个“长链路”集成测试（prompt -> tool -> bg -> continue -> final）。
  - 对可能不稳定场景给出“最小复现实例 + 断言”。
- 文档（必须）：
  - 在 `REVIEW-LOG` 记录风险点与验证结论；
  - 若用户可见行为变化，更新 `README.md` 对应段落。

## 验证方式
- 命令：
  - `swift test --filter Agent`
  - `swift test --filter PromptController`
  - `swift test --filter TranscriptRenderer`
  - `swift test --filter AI`
  - `swift test`
- 预期结果：
  - 全量回归绿；
  - 无新增 flaky 测试；
  - 并发/取消语义保持一致。

## 风险与回滚
- 风险：
  - 测试场景增加后执行耗时上升；
  - 异步时序测试存在偶发不稳定。
- 回滚点：
  - 将不稳定场景拆为更小粒度测试，降低时序耦合。
