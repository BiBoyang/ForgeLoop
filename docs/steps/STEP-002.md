# STEP-002：AgentLoop 工具调用事件骨架

## 目标
- 在不引入完整工具执行细节的前提下，先把 `AgentLoop` 的“工具调用生命周期事件”骨架搭起来。
- 让后续 STEP 可以在此基础上逐步接入真实工具执行。

## 实现范围
- 模块：`ForgeLoopAgent`
- 文件：
  - `Sources/ForgeLoopAgent/AgentTypes.swift`
  - `Sources/ForgeLoopAgent/AgentLoop.swift`
  - `Sources/ForgeLoopAgent/Agent.swift`（仅在需要状态映射时改）
  - `Tests/ForgeLoopAgentTests/`（新增工具事件相关测试）

## 实现要求

### 1) 事件模型补齐（先最小字段）
- 在 `AgentEvent` 新增：
  - `toolExecutionStart(toolCallId: String, toolName: String, args: String)`
  - `toolExecutionEnd(toolCallId: String, toolName: String, isError: Bool)`
- `type` 字段映射补齐：
  - `tool_execution_start`
  - `tool_execution_end`

> 说明：当前项目 `ToolCall.arguments` 是 `String`，本 step 先按 `String` 传递，避免提前引入 JSONValue 复杂度。

### 2) AgentLoop 增加“识别 tool_call 并发事件”骨架
- 在 assistant final message 产出后：
  - 扫描 `AssistantMessage.content` 中的 `.toolCall(...)` block。
  - 对每个 tool call 依次 emit：
    1. `toolExecutionStart(...)`
    2. `toolExecutionEnd(..., isError: true)`（占位：当前先统一 not-implemented）
- 同时保留现有 `turnEnd / agentEnd` 闭环，不要破坏现有消息流测试。

### 3) 占位策略（必须可观察）
- 暂不执行真实工具，但要体现“工具阶段存在”：
  - 可以先不注入 tool_result message；
  - 但必须发出 start/end 事件，保证 TUI 后续可接入。

### 4) Agent 状态映射（可选最小）
- 若你决定在 `Agent` 里记录 pending tool calls，可加最小状态（非必须）。
- 本 step 最重要是事件可观测，不强制状态字段。

## 验收标准
- 当 provider 返回含 `.toolCall` 的 assistant message 时：
  - 事件流中出现 `toolExecutionStart -> toolExecutionEnd`。
  - 数量与 toolCall block 数量一致，顺序一致。
- 不含 toolCall 时，不应出现 toolExecution* 事件。
- 既有 `AgentContinueTests` 不回归失败。

## 建议测试用例（至少 3 个）
1. 单个 toolCall：断言 start/end 各 1 次，且顺序正确。
2. 多个 toolCall：断言事件数量与顺序按 source order。
3. 无 toolCall：断言无 toolExecution 事件。

## 验证命令
- `swift test --filter Agent`

## 提交前注意
- 只做骨架，不要在本 step 引入完整工具系统（避免范围失控）。
