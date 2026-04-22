# STEP-004：TUI 输入态与 streaming 态行为分流（Enter: prompt/steer）

## 目标
- 在 CLI 交互层实现“同一个 Enter，按 Agent 状态分流”：
  - idle 时：发送 `prompt`；
  - streaming 时：入队 `steer`，不触发第二个并发 run。
- 对用户可见行为是：streaming 期间输入不会丢、不会报并发错误，且可在后续 `continue()` 中消费。

## 实现范围
- 模块：`ForgeLoopCli`（主），`ForgeLoopAgent`（仅暴露最小辅助 API 时可改）
- 文件建议：
  - `Sources/ForgeLoopCli/CodingTUI.swift`
  - `Sources/ForgeLoopCli/TUIRunner.swift`（仅在按键分发需要补钩子时改）
  - `Tests/ForgeLoopCliTests/`（新增输入分流测试）

## 实现要求

### 1) Enter 行为分流
- 在 Enter 处理逻辑中：
  - 若 `agent.state.isStreaming == false`：走 `agent.prompt(...)`
  - 若 `agent.state.isStreaming == true`：走 `agent.steer(.user(UserMessage(text: ...)))`
- streaming 分支必须：
  - 清空输入框；
  - 不调用 `agent.prompt`；
  - 可选追加一条轻量 UI 提示（如“queued 1 prompt”）。

### 2) 错误语义
- streaming 时按 Enter 不应抛 `alreadyRunning` 到 UI。
- 任何 `alreadyRunning` 都应被视为交互分流失败（此 step 目标是避免出现）。

### 3) 队列可见性（最小）
- 输入分流后，用户可从现有 queue 面板/提示中看到消息已排队（若你目前是简化 TUI，至少保证 `queuedSteeringMessages().count` 可观测）。

### 4) 与现有 continue 机制衔接
- streaming 中被 steer 的消息，后续应可通过 `continue()` 消费。
- 不要求本 step 自动触发 `continue()`；只保证队列语义和 UI 分流行为正确。

## 验收标准
- idle 输入一次 Enter 后：`messages` 增加 user + assistant。
- streaming 输入一次 Enter 后：`queuedSteeringMessages().count += 1`，且无并发错误。
- 结束 streaming 后执行 `continue()`：能消费队列并追加对应消息。

## 建议测试用例（至少 4 个）
1. `testEnterWhenIdleCallsPromptPath`
2. `testEnterWhenStreamingQueuesSteerPath`
3. `testStreamingEnterDoesNotCallPromptTwice`
4. `testQueuedPromptAfterStreamingCanBeConsumedByContinue`

> 若当前 TUI 难以直接单测键盘事件，可抽出一个纯函数/小控制器，例如：
> `handleEnter(text:isStreaming:agent:)`，然后做单测。

## 验证命令
- `swift test --filter Cli`
- `swift test --filter Agent`

## 提交前注意
- 本 step 不做 UI 外观优化，只做行为正确性。
- 避免把“输入分流”逻辑散落在多个 closure；尽量集中在一个可测入口。
