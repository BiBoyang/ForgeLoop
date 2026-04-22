# STEP-006：OpenAI Responses Provider 最小接入

## 目标
- 在现有 `ForgeLoopAI` 里新增一个真实可用的 OpenAI Responses provider（SSE 流式）。
- 保持与当前 `AssistantMessageStream` 事件模型兼容，先打通 text 流，不在本 step 做完整 function-call 细节。

## 实现范围
- 模块：`ForgeLoopAI`
- 文件建议：
  - `Sources/ForgeLoopAI/OpenAIResponsesProvider.swift`（新增）
  - `Sources/ForgeLoopAI/RegisterBuiltins.swift`（注册入口）
  - `Sources/ForgeLoopAI/APIRegistry.swift`（通常无需改，除非注册辅助）
  - `Sources/ForgeLoopAI/SSEParser.swift`（如需小修）
  - `Tests/ForgeLoopAITests/OpenAIResponsesProviderTests.swift`（新增）

## 实现要求

### 1) Provider 基本结构
- 实现 `APIProvider`：
  - `api` 建议为 `openai-responses`
  - `stream(model:context:options:) -> AssistantMessageStream`
- 请求目标：`{baseUrl}/v1/responses`
- Header 至少包含：
  - `content-type: application/json`
  - `accept: text/event-stream`
  - `authorization: Bearer <apiKey>`

### 2) 请求体（最小）
- 最小字段：
  - `model`
  - `stream: true`
  - `input`（把当前 `Context.messages` 映射成可用格式）
- 本 step 可先做 text-only 输入映射（user/assistant 文本），function call 细节放下一步。

### 3) SSE 事件到 AssistantMessageEvent 映射（最小可用）
- 支持以下路径：
  - `response.output_text.delta` -> `.textDelta(...)`
  - `response.completed` -> `.done(...)` + `end(...)`
  - `response.failed/response.error` -> `.error(...)` + `end(...)`
- 保证事件闭环：
  - 至少发 `.start`
  - 正常结束发 `.done`
  - 错误结束发 `.error`
  - 只 `end(...)` 一次

### 4) 取消语义
- `options.cancellation` 命中时：
  - 产出 `.error(reason: .aborted, ...)`
  - `end(abortedMessage)`
  - 不得再发 `.done`

### 5) 注册入口
- 在 `registerBuiltins` 增加可选注册（用环境变量 `OPENAI_API_KEY`）。
- 不影响现有 FauxProvider 测试路径。

## 验收标准
- 能在单测中用 stubbed SSE 数据流驱动 provider，拿到 textDelta + done。
- 错误 SSE 事件能落到 `.error` 结束。
- 取消时能落到 `.aborted` 且无 `.done`。

## 建议测试用例（至少 4 个）
1. `testResponsesTextDeltaThenDone`
2. `testResponsesErrorEventEndsWithError`
3. `testResponsesCancellationEndsAborted`
4. `testRegisterBuiltinsRegistersOpenAIWhenApiKeyPresent`（可选）

## 验证命令
- `swift test --filter OpenAIResponses`
- `swift test --filter AI`
- `swift test`（回归）

## 提交前注意
- 先做最小可用 text 流，不要在这一步扩展过多 provider 方言字段。
- 保持事件语义一致优先于“覆盖所有 OpenAI 事件类型”。
