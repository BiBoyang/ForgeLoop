# STEP-001：Agent `continue()` 与队列雏形

## 目标
- 为 `Agent` 增加最小可用的“继续执行”能力：
  - 支持 `continue()`；
  - 支持 `steering queue`；
  - 在 streaming 期间可安全入队，不触发并发运行冲突。

## 实现范围
- 模块：`ForgeLoopAgent`
- 重点文件：
  - `Sources/ForgeLoopAgent/Agent.swift`
  - `Sources/ForgeLoopAgent/AgentTypes.swift`
  - （建议新增）`Sources/ForgeLoopAgent/PendingMessageQueue.swift`
  - `Tests/ForgeLoopAgentTests/AgentSmokeTests.swift`（可拆新测试文件）

## 具体要求

### 1) 新增队列能力（最低限度）
- 在 `Agent` 内增加：
  - `steer(_ message: Message)`：入队；
  - `clearSteeringQueue()`；
  - `queuedSteeringMessages() -> [Message]`（给 UI 展示）。
- 建议独立一个轻量 `PendingMessageQueue`（NSLock 保护）：
  - `enqueue(_:)`
  - `drain() -> [Message]`
  - `snapshot() -> [Message]`
  - `clear()`

### 2) 新增 `continue()` 行为
- 在 `Agent` 增加 `public func continue() async throws`。
- 规则（先做这个最小版）：
  1. 若当前 transcript 为空：抛 `noMessagesToContinue`。
  2. 若有 `steering queue`：优先 drain 并走 `AgentLoop.run(prompts: queued, ...)`。
  3. 若最后一条消息是 `.user`：走 `AgentLoop.run(prompts: [], ...)` 或 `runContinue`（二选一，但行为要一致）。
  4. 若最后一条是 `.assistant` 且 queue 为空：抛 `cannotContinueFromAssistant`（需在 `AgentError` 新增）。

### 3) 并发一致性
- 继续沿用 `runLifecycle()` 作为唯一执行入口。
- 不允许出现两个并发 run；违反时仍抛 `alreadyRunning`。

## 验收标准
- `agent.prompt("A")` 后再 `continue()`：
  - 不崩溃；
  - 生命周期事件闭环正常。
- streaming 过程中 `agent.steer(.user(...))`：
  - 不触发第二个 run；
  - 在下一次 `continue()` 能被消费。
- queue 清理接口行为正确（snapshot / clear / drain）。

## 建议测试用例（至少 3 个）
1. `continue` on empty transcript -> throws `noMessagesToContinue`。
2. 有 queued steering 时 `continue()` 消费队列并追加消息。
3. 最后一条 assistant 且 queue 空时 `continue()` 抛新错误。

## 验证命令
- `swift test --filter Agent`

## 提交前自检
- 没有改动 `ForgeLoopCli`（本 step 不需要）。
- `Agent` 对外 API 命名清晰，避免后续重构成本。
