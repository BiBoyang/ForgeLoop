# STEP-005：FauxProvider 流式中止一致性

## 目标
- 让 `FauxProvider` 的取消（abort/cancellation）语义与 Agent 事件消费侧保持一致。
- 确保中止场景下事件序列可预测，不出现“半闭环”或重复结束。

## 实现范围
- 模块：`ForgeLoopAI`（主），`ForgeLoopAgent`（仅在测试接线需要时微调）
- 文件建议：
  - `Sources/ForgeLoopAI/FauxProvider.swift`
  - `Sources/ForgeLoopAI/AssistantMessageStream.swift`（通常无需改，除非暴露状态断言辅助）
  - `Tests/ForgeLoopAITests/`（新增 Faux cancel 语义测试）
  - 可补充 `Tests/ForgeLoopAgentTests/` 1 个集成测试验证 `agent.abort()`

## 实现要求

### 1) 取消事件语义统一
- 当 `options?.cancellation?.isCancelled == true` 时：
  - 推送 `AssistantMessageEvent.error(reason: .aborted, error: abortedMessage)`；
  - `end(abortedMessage)`；
  - 立即 return，且不得再发 `done`。

### 2) 结束幂等
- 任意路径只允许一次 `end(...)`；
- 不得出现 `.error(.aborted)` 后又 `.done(...)` 的双终止。

### 3) 部分输出保留
- 若在流式中途被取消，`abortedMessage` 可以带已有 partial text（保持可观察性）；
- 但 `stopReason` 必须是 `.aborted`。

### 4) 与 Agent 对齐
- Agent 在消费该 stream 时，应最终落到 assistant stopReason `.aborted` 或 errorMessage 对应的失败消息，不出现悬挂状态。

## 验收标准
- 取消场景：事件序列包含 aborted error，且无 done。
- 非取消场景：保持现有 done 路径，不回归。
- `agent.abort()` 触发后，`isStreaming` 能正确归零（回归检查）。

## 建议测试用例（至少 4 个）
1. `testCancellationEmitsAbortedErrorAndEnds`
2. `testCancellationDoesNotEmitDoneAfterError`
3. `testNonCancelledStreamStillEndsWithDone`
4. `testAgentAbortWithFauxProviderProducesAbortedAssistant`

## 验证命令
- `swift test --filter Faux`
- `swift test --filter Agent`
- 最后全量：`swift test`

## 提交前注意
- 保持 FauxProvider 简洁，不要在本 step 引入真实网络 provider 复杂度。
- 重点是“中止语义一致”，不是“模拟更复杂模型行为”。
