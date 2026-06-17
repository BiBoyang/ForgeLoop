# ForgeLoop 深度 Review 修复清单

> 生成时间：2026-06-17  
> Review 范围：`/Users/boyang/Desktop/WebKit_build/ForgeLoop`  
> 基线状态：`swift build` ✅ 通过，`swift test` ✅ 494 个测试全部通过  
> 说明：本清单按 **P0（必须立即修）/ P1（本周内修）/ P2（近期优化）** 分级，待问题全部修复后再决定是否删除或归档。

---

## 阅读指南

- **P0**：安全漏洞、竞态导致状态不一致、架构契约被严重破坏。建议优先处理。
- **P1**：重要缺陷，影响正确性、稳定性或可维护性，但不会立即造成严重后果。
- **P2**：优化项、文档同步、代码整洁度提升。
- 每条包含：**问题 → 影响 → 改动点 → 建议方案 → 验收标准 → 注意事项**。

---

# P0：阻断性/高风险（7 项）

## P0-1 消除 CLI/App 对 `AgentState` 的直接写入 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `CodingTUI.swift:333-335`、`SlashCommandRegistry.swift:141/151/305-307`、`AppController.swift:179/181/195/197/399` 直接修改 `agent.state.messages` / `model` / `compact()`。 |
| **影响** | 违反 `AGENTS.md` 分层契约；Agent 无法保证状态变更的事件闭环、hook 触发、并发安全。 |
| **改动点** | `Sources/ForgeLoopAgent/Agent.swift` 新增公共方法；`Sources/ForgeLoopCli/*`、`Sources/ForgeLoopApp/AppController.swift` 移除直接 state 写入。 |
| **建议方案** | 在 `Agent` 上新增：<br>1. `public func restoreSession(messages: [Message], modelID: String) async throws`<br>2. `public func switchModel(to modelID: String) async throws`<br>3. `public func compactContext() async -> ContextCompactResult`<br>方法内部通过 `state` 的锁保护更新，并 emit `.contextCompacted` / `.agentStart` 等事件（或通知 listener）。CLI/App 全部改为调用这些方法。 |
| **验收标准** | 1. 全仓库搜索不到 `agent\.state\.(messages\|model)\s*=` 和 `\.state\.compact\(\)`。<br>2. 现有 session 恢复、`/model`、`/compact` 功能回归测试通过。<br>3. 新增测试：状态变更必须通过 Agent 公共 API 完成。 |
| **注意事项** | `switchModel` 需要处理 model ID 到 `Model` 的解析（可复用 `switchedModel(from:to:)` 逻辑，但移到 Agent 内部或一个共享 utility）。 |

---

## P0-2 修复 `AssistantMessageStream` 竞态 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `push()` 在锁外 `resume(waiter)`，`end()` 可能在这期间设置 `ended=true` 并清空 waiters，导致消费者在 end 后仍收到非 nil 事件。 |
| **影响** | 破坏 `messageStart -> messageUpdate* -> messageEnd` 闭环；cancel 后可能双终止。 |
| **改动点** | `Sources/ForgeLoopAI/AssistantMessageStream.swift:42-75`。 |
| **建议方案** | 方案 A（推荐）：把 `waiter.resume(returning: event)` 移到锁内，但用 `lock.withLock` + 立即 resume 避免死锁。<br>方案 B：在 `push` 移除 waiter 后、resume 前，再次检查 `ended`；若已 end 则改 resume nil 并丢弃事件。<br>同时增加 buffer 上限/反压：buffer 过大且无 waiter 时丢弃旧事件或提前结束。 |
| **验收标准** | 1. 新增压力测试：高并发 push + 提前结束，断言 end 后不再收到非 nil 事件。<br>2. 现有 `AssistantMessageStreamTests` 通过。 |
| **注意事项** | 不要在持锁时做可能 await 的操作；`resume` 是同步的，可以放在锁内。 |

---

## P0-3 修复 `CancellationHandle` 已取消后注册的回调不触发 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | 当 `cancel(reason: nil)` 时，`reasonValue = nil`。之后通过 `onCancel` 注册的回调会进入 `if _isCancelled { return reasonValue }` 分支，得到 `fireNow = nil`，而 `if fireNow != nil` 为 false，导致回调**永远不会触发**。只有当 cancel 时传入非 nil 的 reason，late-registered 回调才会触发。 |
| **影响** | Provider/工具在取消后注册的取消回调可能不被调用，取消失效被静默忽略。 |
| **改动点** | `Sources/ForgeLoopAI/Cancellation.swift:33-42`。 |
| **建议方案** | 使用独立的布尔标记区分“已取消（reason 可能为 nil）”和“未取消”：<br>```swift<br>public func onCancel(_ callback: @escaping @Sendable (String?) -> Void) {<br>    let (shouldFire, reason): (Bool, String?) = lock.withLock {<br>        if _isCancelled {<br>            return (true, reasonValue)<br>        }<br>        handlers.append(callback)<br>        return (false, nil)<br>    }<br>    if shouldFire {<br>        callback(reason)<br>    }<br>}<br>``` |
| **验收标准** | 1. 新增测试：`cancel(reason: nil)` 后注册的回调必须被调用一次，且收到的 reason 为 nil。<br>2. 新增测试：`cancel(reason: "xxx")` 后注册的回调必须被调用一次，且收到 reason 为 `"xxx"`。<br>3. 现有取消相关测试通过。 |
| **注意事项** | callback 在锁外调用，避免死锁；callback 内部不要再同步调用 `cancel`。<br>注：之前描述的“检查和 append 非原子”不准确，当前代码的原子性是正确的，真正 bug 是 nil reason 导致 late-registered 回调丢失。 |

---

## P0-4 修复 `BashTool` / `ProcessRunner` 命令注入 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `ProcessRunner.run` 使用 `/bin/sh -c <command>` 执行 LLM 提供的字符串；`BashTool` 原样传入。 |
| **影响** | LLM 或被诱导输入可执行任意 shell 命令，读取/修改任意文件，是最严重的安全漏洞。 |
| **改动点** | `Sources/ForgeLoopAgent/Tooling/ProcessRunner.swift`、`Sources/ForgeLoopAgent/Tooling/BashTool.swift`。 |
| **建议方案** | **分两步走：**<br>**第一步（最小改动，立即生效）：** 在 `BashTool` 参数解析后增加审计层：<br>1. 如果 `command` 包含 `;`、`&`、`` ` ``、`$()`、管道 `\|`、重定向 `>` 等 shell 元字符，返回错误并提示 LLM 使用简单命令。<br>2. 为命令添加白名单或危险命令黑名单（如 `rm -rf /`、`curl` 外发等）可选拦截。<br><br>**第二步（推荐，架构更正确）：** 扩展 `ProcessRunner.run` 支持 `args: [String]?` 参数：<br>```swift<br>public static func run(command: String, args: [String]? = nil, cwd: String, ...)<br>```<br>当 `args` 提供时，直接 `process.executableURL = URL(fileURLWithPath: command)`、`process.arguments = args`，不走 shell。`BashTool` 的 schema 增加 `args: [String]` 可选参数，优先使用 args 模式。 |
| **验收标准** | 1. 新增测试：注入 `"; cat /etc/passwd"`、`"$(id)"` 等，断言工具返回错误而非执行。<br>2. 现有 `BashToolTests` 通过。<br>3. 简单命令如 `ls`、`pwd` 仍正常工作。 |
| **注意事项** | 保留 `sh -c` 作为 fallback 时必须有明确的审计/白名单；不要直接 break 现有简单命令的行为。 |

---

## P0-5 修复 API key 凭证安全 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | 1. `CredentialStore` 明文存储 API key 到 `~/.config/forgeloop/credentials.json`。<br>2. 使用默认文件权限（通常 0644）。<br>3. `ForgeLoop.runLogin()` 使用 `readLine()` 回显输入。 |
| **影响** | 凭证泄露风险：同机用户可读、终端历史可记录。 |
| **改动点** | `Sources/ForgeLoopCli/CredentialStore.swift`、`Sources/ForgeLoopCli/ForgeLoop.swift:15-28`。 |
| **建议方案** | **阶段 1（最小安全基线）：**<br>1. 写入文件时设置权限 `0600`。<br>2. 使用 atomic write：`Data.write(to:options: .atomic)` 或写临时文件后 `replaceItemAt`。<br>3. `runLogin()` 隐藏回显，使用 `getpass(3)` 或 `FileHandle.standardInput` raw mode 读取。<br><br>**阶段 2（推荐）：** 迁移到 macOS Keychain：<br>1. 新增 `KeychainCredentialStore`，使用 `Security` 框架存取 generic password。<br>2. `CredentialStore` 改为兼容层：先尝试 Keychain，fallback 到文件（并提示迁移）。 |
| **验收标准** | 1. 新增测试：保存后文件权限为 `0600`（或更严格）。<br>2. `AuthAndLabelTests` 通过。<br>3. `runLogin` 不直接回显输入（至少单元测试验证读取逻辑）。 |
| **注意事项** | Keychain 迁移需要考虑现有用户已保存的明文文件，首次启动时自动导入并删除明文文件。 |

---

## P0-6 修复 `SessionStore` 路径遍历 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `save(name:)` 直接把用户输入拼接到文件路径，未过滤 `..`、`/` 等。 |
| **影响** | 可通过 `/save ../foo` 写入 `~/.config/forgeloop/foo.json` 或跳出该目录。 |
| **改动点** | `Sources/ForgeLoopCli/SessionStore.swift:23-42`。 |
| **建议方案** | 1. 新增 `SessionName` 值类型，init 时校验只允许 `A-Z a-z 0-9 _ -`。<br>2. `save(name:)` 接受 `SessionName`，或在方法内对 `name` 做严格校验，拒绝包含路径分隔符、`.` 开头的输入。<br>3. `load`/`delete` 同样校验。<br>4. 写入使用 atomic write。 |
| **验收标准** | 1. 新增测试：`save(name: "../evil")` 抛出错误；`save(name: ".hidden")` 抛出错误。<br>2. 正常 session 保存/加载/列表功能回归。 |
| **注意事项** | 需要同步更新 `SlashCommandRegistry` 中对 `/save` 错误的展示文案。 |

---

## P0-7 修复 `ForgeLoopApp` 中 `/attach` 无效 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `AppController.submit()` 处理 slash 命令时 `let attachmentStore = AttachmentStore()`，每次都新建空实例。 |
| **影响** | AppKit 前端 `/attach` 命令实际无效，附件不会进入后续消息。 |
| **改动点** | `Sources/ForgeLoopApp/AppController.swift`、`Sources/ForgeLoopApp/TabSession.swift`。 |
| **建议方案** | 1. 在 `TabSession` 中持有一个稳定的 `AttachmentStore` 实例。<br>2. `AppController` 处理 `/attach` 时操作 `currentTabSession.attachmentStore`。<br>3. 正常 submit 路径把附件注入到 prompt 中（复用 `PromptController` 的附件注入逻辑）。<br>4. 或：如果 AppKit 前端暂不支持附件，显式禁用 `/attach` 并返回提示。 |
| **验收标准** | 1. 新增 `AttachmentStoreTests` 级别的 AppKit 集成测试，或至少保证 `AppController` 单元测试验证附件被正确注入。<br>2. `/attach` 后发送消息，验证附件内容出现在 `Message.user` 中。 |
| **注意事项** | 这是跨前端状态共享问题的一个缩影，建议结合 P1-9 一起重构。 |

---

# P1：重要缺陷（12 项）

## P1-1 修复 `SSEParser` 线程安全 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `SSEParser` 标 `@unchecked Sendable` 但内部状态无锁/actor 保护。 |
| **影响** | 潜在数据竞争，尽管当前每个 stream 单线程使用。 |
| **改动点** | `Sources/ForgeLoopAI/SSEParser.swift`；四个 Provider 中 `let parser` 改为 `var parser`。 |
| **建议方案** | 将 `SSEParser` 改为 `struct`，所有方法改为 `mutating`；天然值语义线程安全，无需 `@unchecked Sendable`。 |
| **验收标准** | 移除 `@unchecked Sendable` 后编译通过；新增 `SSEParserTests` 覆盖基本解析、值语义、高频顺序、跨 Task 传递；`swift test` 全绿。 |

---

## P1-2 收紧 `Agent` 的公开可变配置属性 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `Agent.apiKeyResolver` / `toolExecutor` / `backgroundTaskManager` / `cwd` / `toolExecutionMode` 是公开 `var`，无同步。 |
| **影响** | 跨隔离域读写可能数据竞争；`makeLoopConfig` 读取到半一致快照。 |
| **改动点** | `Sources/ForgeLoopAgent/Agent.swift:36-40`。 |
| **建议方案** | 1. 新增 `LockedAgentConfig`，用 `NSLock` 保护 `apiKeyResolver` / `cwd` / `toolExecutionMode` / `backgroundTaskManager`。<br>2. `toolExecutor` 改为 `let`（init 后不再重新赋值）。<br>3. `Agent` 的公开属性通过 `LockedAgentConfig` 的 getter/setter 访问；`makeLoopConfig` 调用 `loopSnapshot()` 获取一致快照。 |
| **验收标准** | 1. 编译通过。<br>2. 新增并发读写测试不崩溃；`swift test` 全绿。 |

---

## P1-3 修复 `PathGuard` symlink 绕过 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `PathGuard.resolve` 不解析符号链接，`cwd` 内部 symlink 可指向外部目录。 |
| **影响** | 文件工具可越界访问 `/etc` 等敏感目录。 |
| **改动点** | `Sources/ForgeLoopAgent/Tooling/PathGuard.swift`、`FindTool.swift`、`GrepTool.swift`、`ListTool.swift`。 |
| **建议方案** | 1. `PathGuard.init` 与 `resolve` 在比较前调用 `resolvingSymlinksInPath()`。<br>2. `FindTool` / `GrepTool` 枚举时默认不跟随 symlink（检查 `isSymbolicLinkKey` 并 `skipDescendants`）。<br>3. `ListTool` 将 symlink 标记为 `l` 前缀。 |
| **验收标准** | 新增 `PathGuardSymlinkTests`：cwd 内指向外部目录的 symlink 被 `read`/`list`/`grep`/`find` 拒绝；内部 symlink 仍可访问；`swift test` 全绿。 |

---

## P1-4 补全 `EditTool` 校验、锚点、回滚 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `EditTool` 未使用 `ToolArgsValidator`；只替换第一处匹配；无备份；无锚点。 |
| **影响** | LLM 容易误替换；一旦出错不可恢复。 |
| **改动点** | `Sources/ForgeLoopAgent/Tooling/EditTool.swift`、`Sources/ForgeLoopAgent/Tooling/BuiltinTools.swift`。 |
| **建议方案** | 1. 在 `BuiltinTools.swift` 为 `EditTool` 声明完整 JSON schema，使用 `ToolArgsValidator`。<br>2. 增加 `anchor` / `lineNumber` / `replaceAll` / `caseInsensitive` 参数。<br>3. 替换前写入 `.filename.ext.bak`。<br>4. 匹配不唯一时返回错误提示 LLM。 |
| **验收标准** | 1. `EditToolTests` 覆盖 schema 校验失败、锚点匹配、备份生成。<br>2. 现有编辑功能回归。 |

---

## P1-5 统一 Provider 取消模型，减少 `Task.detached` [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | 四个 Provider 都用 `Task.detached` 启动网络拉流，与调用者任务树脱离。 |
| **影响** | 调用者取消外层任务时 worker 不自动取消；资源泄漏。 |
| **改动点** | 四个 Provider 的 `stream()` 方法。 |
| **建议方案** | 最小改动：将 `Task.detached` 改为 `Task`，保留 `options.cancellation?.onCancel { worker.cancel() }`；worker 内部已有 `Task.isCancelled` 检查。FauxProvider 补充 worker 变量与 `onCancel`。 |
| **验收标准** | 1. 现有 Provider 测试通过。<br>2. `FauxProviderCancellationTests.testCancellationExitsWorkerPromptly` 验证 CancellationHandle 取消后 worker 立即退出；`swift test` 全绿。 |

---

## P1-6 修复 `FauxProvider` 取消被吞 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `emitAbortIfNeeded()` 不检查 `Task.isCancelled`；`try? await Task.sleep` 吞取消异常。 |
| **影响** | 测试替身无法正确模拟取消，可能掩盖真实取消 bug。 |
| **改动点** | `Sources/ForgeLoopAI/FauxProvider.swift`。 |
| **建议方案** | 1. 所有 mode 的 `emitAbortIfNeeded()` 增加 `Task.isCancelled \|\| options?.cancellation?.isCancelled` 检查。<br>2. `try? await Task.sleep` 改为 `try await Task.sleep`，捕获 `CancellationError` 后 emit abort 并 `return`。 |
| **验收标准** | `FauxProviderCancellationTests` 通过；`swift test` 全绿。 |

---

## P1-7 `AgentLoop` 显式检查取消 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `while true` 主循环没有显式检查取消。 |
| **影响** | Provider 不抛错时可能产生无效 turn。 |
| **改动点** | `Sources/ForgeLoopAgent/AgentLoop.swift:137`。 |
| **建议方案** | 在工具执行完成后、进入下一轮前检查 `Task.isCancelled \|\| cancellation?.isCancelled == true`，若取消则 emit `.agentEnd` 并 return。 |
| **验收标准** | 新增 `testCancellationPreventsExtraTurn`：cancel 后 `AgentLoop.run` 结束且不产生额外 turn；`swift test` 全绿。 |

---

## P1-8 子 agent 传播 cancellation [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `SubagentTool.execute` 收到 `cancellation` 但未传给 `runSubagent`。 |
| **影响** | 父 agent 取消时子 agent 继续运行。 |
| **改动点** | `Sources/ForgeLoopAgent/SubagentTool.swift`、`Sources/ForgeLoopAgent/SubagentRunner.swift`。 |
| **建议方案** | 1. `runSubagent` 增加 `cancellation: CancellationHandle?` 参数。<br>2. 在子 agent prompt 外层包 `withTaskCancellationHandler { childAgent.abort() }`。 |
| **验收标准** | 新增测试：父任务 cancel 后，子 agent 的 tool 执行也被终止。 |

---

## P1-9 跨前端共享会话逻辑（CLI / AppKit）

| 项目 | 内容 |
|---|---|
| **问题** | `CodingTUI.swift` 和 `AppController.swift` 各自维护 model switch、附件、queue、footer status 等逻辑，行为漂移。 |
| **影响** | AppKit 前端功能永远落后；维护成本高。 |
| **改动点** | 新增 `Sources/ForgeLoopCli/SessionCoordinator.swift`（或 `ForgeLoopApp/SessionViewModel.swift` 共用）。 |
| **建议方案** | 1. 新建 `SessionCoordinator`：持有一个 `Agent`、一个 `AttachmentStore`、一个 `PendingMessageQueue`、footer status 状态机。<br>2. 提供 `submit(_:)`、`switchModel(_:)`、`attach(_:)`、`detach(_:)`、`compact()` 等方法，内部调用 Agent 公共 API。<br>3. `CodingTUI` 和 `AppController` 只负责把 `SessionCoordinator` 的状态渲染到各自平台。<br>4. 这样 P0-1 和 P0-7 自然被解决。 |
| **验收标准** | 1. `CodingTUI` 行数从 600+ 降到 200 以内。<br>2. `AppController` 复用同一 coordinator，支持附件、queue、model switch、footer status。<br>3. 现有 CLI/App 测试通过。 |
| **注意事项** | 这是较大重构，建议拆成多个 PR：先抽 coordinator，再迁移 CLI，再迁移 AppKit。 |

---

## P1-10 后台任务资源上限 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | 1. `BackgroundTaskManager` 无默认超时、并发上限、输出上限、清理策略。<br>2. `start()` 是 actor 方法，内部创建 `Task {}` 继承 actor 隔离，长时间运行的后台任务会占用 actor 的 serial executor；`cancel()` / `status()` 等调用需等待 task 挂起才能执行。 |
| **影响** | 1. 长期运行后台任务可能耗尽内存/进程资源。<br>2. actor 内长时间任务可能阻塞其他 actor 方法，产生隐式排队延迟。 |
| **改动点** | `Sources/ForgeLoopAgent/BackgroundTaskManager.swift`、`Sources/ForgeLoopAgent/Tooling/BgTool.swift`。 |
| **建议方案** | 1. 默认超时 5 分钟，暴露 `timeoutMs` 参数。<br>2. 最大并发后台任务数（如 8）。<br>3. 输出写入临时文件或环形缓冲区，限制单任务输出大小（如 64KB）。<br>4. 任务完成后定期清理或限制保留数量。<br>5. 考虑将实际进程执行从 actor 隔离中移出：用 `Task.detached` 或独立 `Task`（非 actor-isolated）运行 `ProcessRunner.run`，actor 只负责状态登记、取消句柄管理和查询；取消时通过 `CancellationHandle` 通知 detached task。 |
| **验收标准** | 1. 新增测试：超时任务被 kill、超并发返回错误、大输出被截断。<br>2. 新增测试：启动后台任务后，立即调用 `cancel()` / `status()` 不阻塞或能快速响应。 |

---

## P1-11 修复 flaky 测试 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `AgentStabilityTests.testBgNotificationWhileStreamingQueuesMessage` 依赖 yield 时序，已出现偶发失败。 |
| **影响** | CI 不稳定。 |
| **改动点** | `Tests/ForgeLoopAgentTests/AgentStabilityTests.swift:236`。 |
| **建议方案** | 使用 `XCTestExpectation` 或 `AsyncStream` 等待 bg 任务真正进入 running 状态后再断言，而非固定 yield 次数。 |
| **验收标准** | 连续运行 10 次 `swift test --filter testBgNotificationWhileStreamingQueuesMessage` 全部通过。 |

---

## P1-12 修复 `OpenAIResponsesProvider` 丢失 tool_call 上下文 [DONE]

| 项目 | 内容 |
|---|---|
| **问题** | `buildInput` 对 `.assistant` 消息只提取文本，忽略 `.toolCall`；对 `.tool` 用前缀文本拼接。 |
| **影响** | Responses API 多轮工具调用时模型无法正确关联 tool_call_id。 |
| **改动点** | `Sources/ForgeLoopAI/OpenAIResponsesProvider.swift` 的 `InputItem` 与 `buildInput`。 |
| **建议方案** | 将 `InputItem` 扩展为 enum，支持 `function_call` / `function_call_output` item；`buildInput` 分别输出 assistant 文本、tool_call、tool_result，保留 `call_id` 映射。 |
| **验收标准** | 新增 `testToolCallContextPreservesCallIds`：两轮工具调用的 context 序列中 `call_id` 一致；`swift test` 全绿。 |

---

# P2：优化与文档（8 项）

## P2-1 提取公共测试辅助模块

| 项目 | 内容 |
|---|---|
| **问题** | `EventCollector`、`StreamCallCounter`、`makeStream(_:)`、frame helper 等大量重复。 |
| **改动点** | 新增 `Tests/ForgeLoopTestSupport/` target。 |
| **建议方案** | 将重复辅助类型/函数迁移到 `ForgeLoopTestSupport`，各测试 target 依赖它。 |
| **验收标准** | 重复定义消失；所有测试通过。 |

---

## P2-2 拆分 `CodingTUI`

| 项目 | 内容 |
|---|---|
| **问题** | `runCodingTUIInternal` 600+ 行，职责过多。 |
| **改动点** | `Sources/ForgeLoopCli/CodingTUI.swift`。 |
| **建议方案** | 拆分为 `SessionCoordinator`（P1-9）、`RenderLoop`、`InputLoop`、`KeyBindingDispatcher`。 |
| **验收标准** | `CodingTUI.swift` 主函数控制在 200 行以内。 |

---

## P2-3 改进 `SlashCommandRegistry`

| 项目 | 内容 |
|---|---|
| **问题** | 按单个空格分割、不支持引号、大小写敏感、`/help` 构造默认 registry。 |
| **改动点** | `Sources/ForgeLoopCli/SlashCommandRegistry.swift`。 |
| **建议方案** | 1. 使用 `CharacterSet.whitespacesAndNewlines` 分割。<br>2. 支持简单引号包裹参数。<br>3. `/help` 基于当前 registry 实例生成。<br>4. 提供 `register(_:)` builder API。 |
| **验收标准** | 新增测试覆盖 Tab/多个空格/引号/大小写场景。 |

---

## P2-4 同步文档

| 项目 | 内容 |
|---|---|
| **问题** | README 未覆盖 AppKit；ARCHITECTURE.md 路径错误；AGENTS.md/release checklist 引用不存在文件。 |
| **改动点** | `README.md`、`docs/architecture/ARCHITECTURE.md`、`AGENTS.md`、`docs/release/RELEASE-CHECKLIST.md`。 |
| **建议方案** | 1. README 增加 AppKit Application 章节。<br>2. ARCHITECTURE.md 补充 `ForgeLoopApp` 第四层、修正 ForgeLoopTUI 外部包路径。<br>3. 创建 `docs/03-Step看板.md` 和 `docs/reviews/REVIEW-LOG.md`，或从 AGENTS/release checklist 中移除引用。 |
| **验收标准** | 文档中所有内部链接有效；新贡献者能按文档找到对应文件。 |

---

## P2-5 `FindTool` namePattern 转义

| 项目 | 内容 |
|---|---|
| **问题** | `.` / `+` / `(` 等被当正则元字符。 |
| **改动点** | `Sources/ForgeLoopAgent/Tooling/FindTool.swift:47-50`。 |
| **建议方案** | 先 `NSRegularExpression.escapedPatternForString`，再替换 `*` → `.*`、`?` → `.`。 |

---

## P2-6 `ModelStore` / `CredentialStore` 文件 I/O 序列化

| 项目 | 内容 |
|---|---|
| **问题** | 文件 I/O 无序列化，未来并发保存可能损坏文件。 |
| **改动点** | `Sources/ForgeLoopCli/ModelStore.swift`、`Sources/ForgeLoopCli/CredentialStore.swift`。 |
| **建议方案** | 将 store 改为 actor 或内部加锁。 |

---

## P2-7 性能门禁收紧

| 项目 | 内容 |
|---|---|
| **问题** | `PerformanceGateTests.thresholdFactor = 2.0` 过松。 |
| **改动点** | `Tests/ForgeLoopCliTests/PerformanceGateTests.swift`。 |
| **建议方案** | 分阶段收紧到 1.2–1.5；为 idle-prompt 延迟和吞吐增加断言。 |

---

## P2-8 新增跨 Provider 契约测试

| 项目 | 内容 |
|---|---|
| **问题** | 四个 Provider 分别测试，缺少统一契约。 |
| **改动点** | 新增 `Tests/ForgeLoopAITests/APIProviderContractTests.swift`。 |
| **建议方案** | 参数化测试：同一 context 下所有 Provider 都产生 `.start` → `.textDelta`/`.toolCall` → `.done`/`.error`，且 `stream.result()` 一致。 |

---

# 推荐执行顺序

不要一次改完。建议按以下阶段推进，每个阶段独立可验证：

**阶段 1（安全与不变量，1 周）**
- P0-2 `AssistantMessageStream` 竞态
- P0-3 `CancellationHandle` 竞态
- P0-4 `BashTool` 命令注入
- P0-5 凭证安全
- P0-6 `SessionStore` 路径遍历

**阶段 2（架构边界，1 周）**
- P0-1 消除 CLI/App 直接写 `AgentState`
- P0-7 修复 AppKit `/attach`
- P1-9 跨前端共享 `SessionCoordinator`

**阶段 3（并发与 Provider，1 周）**
- P1-1 `SSEParser`
- P1-2 `Agent` 可变属性
- P1-5 Provider `Task.detached` 重构
- P1-6 `FauxProvider`
- P1-7 `AgentLoop` 取消检查

**阶段 4（工具与测试，1 周）**
- P1-3 `PathGuard` symlink
- P1-4 `EditTool`
- P1-8 子 agent 取消
- P1-10 后台任务资源上限
- P1-11 修复 flaky
- P2-1 测试辅助模块

**阶段 5（文档与优化，随前序阶段同步）**
- P1-12 OpenAIResponsesProvider tool_call
- P2-2 拆分 `CodingTUI`
- P2-3 SlashCommandRegistry
- P2-4 文档同步
- P2-5 ~ P2-8 其他优化

---

# 正面肯定（不是垃圾）

- **分层架构方向正确**：AI → Agent → Cli 依赖方向干净，无循环依赖。
- **事件驱动有骨架**：`AgentEvent` 是 Agent 与 UI 的清晰边界。
- **测试规模到位**：494 个测试，Provider/工具/渲染覆盖充分。
- **Swift 6 编译通过**：`-strict-concurrency=complete` 无并发检查报错。
- **子 agent 递归已阻断**：`childConfig.subagents = []` 是正确的设计。
- **有文档、CHANGELOG、AGENTS.md、性能基线**：开源项目基线规范。

当前状态是：**一辆能跑的车，需要加固刹车、锁上车门、统一仪表盘**。不是从零开始重建。
