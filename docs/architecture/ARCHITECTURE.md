# ARCHITECTURE

本文档是项目架构与关键不变量的单一事实源（SSOT）。

## 1) 分层职责

### ForgeLoopAI
- Provider 抽象与注册：`APIProvider`、`APIRegistry`
- 流式协议与解析：`AssistantMessageStream`、`SSEParser`
- 消息模型：`Message`、`AssistantMessageEvent`、`ToolCall`、`ToolResultMessage`
- 网络抽象：`HTTPClient`

### ForgeLoopAgent
- 生命周期与状态：`Agent`、`AgentState`
- 回合推进：`AgentLoop`
- 事件总线：`AgentEvent`
- 工具执行：`ToolExecutor`、`Read/Write/Bash` 等
- 队列与取消：`PendingMessageQueue`、`CancellationHandle`
- 命令执行沙箱化：`ProcessRunner` 接受可选 `PermissionProfile`，经 `SandboxTransform` 统一包装（见 §4b）；依赖 `ForgeLoopSandbox`

### ForgeLoopCli
- 共享会话逻辑：`SessionCoordinator`（持有一个 `Agent` + `AttachmentStore` + `ModelStore` + `SessionStore` + `SlashCommandRegistry`）
- 会话活动状态：`SessionActivityTracker` 把 `AgentEvent` 折叠成四态 `SessionActivity`（idle/working/done/needsAttention；run 出错 = needsAttention，用户主动 abort = idle），`aggregateSessionActivity` 按 worst-first 聚合多会话；`SessionCoordinator` 持有 tracker 并经 `onActivityChange`（MainActor）发布
- 输入与命令路由：`PromptController`、`CodingTUI`
- 渲染与刷新：`TranscriptRenderer`、`TUI`
- 原则：只消费 `AgentEvent`，不直接写 Agent 内部状态

### ForgeLoopApp
- AppKit GUI 前端：`AppController` + `TabSession`
- 复用 `ForgeLoopCli` 的 `SessionCoordinator` 处理提交、模型切换、附件、session 存取
- 通过 `AgentEventRenderAdapter` 将 `AgentEvent` 渲染到 AppKit 视图
- `AppController` 按职责拆分在多个文件中（`+Window/+Tabs/+Input/+Rendering/+ModelPicker/+MenuBar/+Updates`），窗口装配与 tab 管理分离
- 菜单栏托盘：`MenuBarController`（NSStatusItem，环形 glyph：working 呼吸脉冲、done 绿点、needsAttention 橙点）订阅各 tab `SessionCoordinator.activity`，roster 菜单每项一个 tab（状态点 + 名称/目录，按 needsAttention > done > working > idle 排序），点击激活窗口并选中该 tab；窗口聚焦或切 tab 时 `markActivitySeen()` 清除已查看状态
- 自动更新：Sparkle `SPUStandardUpdaterController` 标准接法（仅 ForgeLoopApp target 依赖 Sparkle）；打包/发布由 `Scripts/build-app.sh` + `.github/workflows/release.yml` 承担（签名/公证/DMG/appcast 全链路），细节见 `docs/RELEASING.md`
- Git 面板：`GitPanelController`（NSSplitView 右侧栏，可折叠且记忆状态）只做视图承载，git 数据全部来自 `ForgeLoopGit`，不在 App 层写 git 逻辑；Changes/History/Worktrees 三段切换，worktree 的创建/打开/删除走 `WorktreeService`，创建成功或 "Open Session" 后以该 worktree 路径为 cwd 开新 tab（tab 级 cwd 粘合，`createNewTab(workingDirectory:)`）

### ForgeLoopGit
- 纯 Foundation 的 git 子进程封装与解析层（机制移植自 termio，MIT）：`GitService`（status/log/diff/commitDiff/currentBranch）、`WorktreeService`（worktree list/add/remove，remove 支持 force，`sanitizedName` 把任意分支名转成安全目录名）、`DiffParser`（unified diff → `FileDiff`/`DiffHunk`/`DiffLine`）、`GitRepositoryLocator`（向上定位仓库根）
- 无状态 `Sendable struct`，git 输出是唯一事实源，不缓存状态；不依赖其他 ForgeLoop target，供 UI 层（git 面板）消费

### ForgeLoopSandbox
- macOS seatbelt 沙箱的策略与包装层（移植自 Codex `sandboxing` crate，映射见 `notes/codex-sandbox-porting-notes.md`）
- 两段式设计（策略 → transform），全部无状态纯函数/`Sendable` 值类型，零 IO 可单测：
  - `PermissionProfile`（`Codable & Sendable`）：fs 维度 `readOnly / workspaceWrite(writableRoots:) / fullAccess` × network 维度 `disabled / enabled`
  - `SeatbeltProfileRenderer`：纯函数 profile → `.sbpl` 文本；`(deny default)` 起手；writableRoots 经 `realpath(3)` canonicalize（`/var` firmlink 陷阱，见 `notes/sandbox-spike-report.md` §4）；base 骨架源自 spike 实测模板
  - `SandboxTransform`：纯函数 (command, args, profile) → argv；`fullAccess + network enabled` 原样透传；`/usr/bin/sandbox-exec` 绝对路径硬编码（防 PATH 注入）
  - `SandboxSupport`：`/usr/bin/sandbox-exec` 存在性检测；非 macOS 明确报不支持
  - `ApprovalPolicy`（`never / onFailure`，默认 onFailure）与 `SandboxDenialHeuristic`（纯函数 (exitCode, stderr) → Bool，锚点：非零退出 + `Operation not permitted` EPERM 文本）
- 不依赖其他 ForgeLoop target；`ForgeLoopAgent` 依赖本模块

## 2) ForgeLoopTUI 内部边界（Core / Adapter）

`ForgeLoopTUI` 是本仓库通过 Swift Package Manager 消费的外部包（参见 `docs/architecture/TUI-深度优化-RFC.md` §3.1）。其内部逻辑上分为两层：

- **TUICore**：通用渲染核心，不依赖任何业务模块。
  - 事件模型：`CoreRenderEvent`（去 chat 语义，源码位于 `ForgeLoopTUI` 包内）
  - 渲染器：`TranscriptRenderer.applyCore(_:)` 为核心入口
  - 增量规划：`StreamingTranscriptAppendState` 负责 transcript append-only streaming 的稳定增量规划
  - 原则：Core 不依赖 `ForgeLoopAI` / `ForgeLoopAgent` / `ForgeLoopCli`
- **TUIChatAdapter**：业务语义适配层。
  - `AgentEvent -> CoreRenderEvent` 映射：`Sources/ForgeLoopCli/AgentEventRenderAdapter.swift`
  - `RenderEvent -> CoreRenderEvent` 兼容映射：`ForgeLoopTUI` 包内的 `LegacyRenderEventAdapter`
  - 旧 `RenderEvent` / `RenderMessage` 已标记 `@available(*, deprecated)`，保留向后兼容

关键不变量：
- 同一语义输入序列下，旧入口 `apply(_:)` 与新入口 `applyCore(_:)` 的输出行完全一致（由 `CoreRenderEventAdapterTests` 保证）。
- `TranscriptRenderer` 当前仅支持 **单个 active block**（`blockStart` 会覆盖之前的 streaming range），`block id` 参数保留用于未来多 block 扩展。

### RenderLoop 调度约束

`RenderLoop`（`Sources/ForgeLoopTUI/RenderLoop.swift`）提供统一帧调度：
- **16ms tick 合帧**：`submit(.normal)` 在 tick 内多次提交只保留最后一帧（latest-frame-wins）。
- **即时刷新**：`submit(.immediate)` 立即 flush 当前 pending frame，不等待 tick。
- **默认开启**：通过环境变量 `FORGELOOP_TUI_RENDER_LOOP=0` 可关闭并回退直出路径。
- **生命周期**：`stop()` 取消 timer 并丢弃 pending frame，退出前必须调用以避免泄漏。

### Inline 渲染增量约束

`TUI` 的 `inlineAnchor` 路径（`Sources/ForgeLoopTUI/TUI.swift`）采用“脏尾段重绘”策略：
- 通过 `firstDifferenceIndex` 找到首个变更行，仅重绘变更尾段（含 1 行上下文），避免全帧清理。
- 同帧重复渲染（内容不变且锚点模式不变）不再输出 ANSI 序列，降低高频流式输出噪声。
- 当锚点模式变化（`cursorOffset` 从 `nil` 到非 `nil` 或反向）时退化为全帧重绘，保证光标语义正确。
- 当当前帧或上一帧物理行数超过终端可视高度时，禁止继续使用 inline 回卷重绘；自动退化为安全的全帧重绘，避免对 scrollback 以上区域做错误覆盖。
- `CodingTUI` 在 **TTY + streaming** 场景下不再走 retained-mode 覆盖式重绘，而是直接追加完整 frame 到 stdout，让终端自然保留 scrollback；streaming 结束后再恢复 inline 输入渲染。
- 为避免整帧追加导致 header / prompt / status 重复刷屏，TTY + streaming 的最终策略收敛为：仅追加 transcript 的稳定增量（新静态行 + 已完成的 assistant 行）；footer（queue/status/input）在 idle 时单独渲染。

### Markdown 增量渲染约束

`ForgeLoopTUI` 引入 `MarkdownEngine` 协议（`Sources/ForgeLoopTUI/MarkdownEngine.swift`）：
- 默认实现 `StreamingMarkdownEngine`：维护单调递增 stable boundary，仅重渲染 unstable tail。
- 未闭合表格在 streaming 阶段降级为纯文本；`isFinal=true` 时收敛为结构化表格渲染。
- 可回退实现 `PlainTextMarkdownEngine`：保留历史按行渲染行为（不做 Markdown 结构化）。

## 3) 核心事件链路
- Provider SSE
- -> `AssistantMessageEvent`
- -> `AgentEvent.messageUpdate`
- -> `TranscriptRenderer.apply`（兼容层）或 `TranscriptRenderer.applyCore`（新入口）
- -> `TUI.requestRender`

该链路中的 UI 侧行为必须「可重放、可覆盖、无副作用」。

## 4) 工具闭环语义（关键）
- assistant 产出 `tool_call`
- `AgentLoop` 先将 assistant 消息 append 到上下文
- 发出 `toolExecutionStart`
- 执行工具并得到 `ToolResult`
- 发出 `toolExecutionEnd`
- 注入 `Message.tool(ToolResultMessage)` 到上下文
- 若存在 `tool_result`，继续下一轮模型请求；否则收敛结束

## 4a) 工具参数契约与错误 taxonomy（长期不变量）

所有内置工具统一通过 `ToolArgsValidator` 做参数 schema 校验，错误输出格式收敛为 `[code] message (path: $.field)`。

### 错误码
- `invalidJson`：入参不是合法 JSON 或不是 object
- `missingRequired`：缺少必填字段
- `invalidType`：字段类型不符（含枚举值越界，如 `mode` 非 `foreground/background`）
- `unknownField`：出现 schema 未声明的字段（已迁移工具启用严格拒绝）
- `missingArgument` / `outsideCwd` / `pathNotFound` / `targetIsDirectory` / `textNotFound` / `executionFailed` / `sizeExceeded` / `timeout` / `cancelled` / `notImplemented` / `unknownTool`：运行时/语义层错误，保持既有含义

### Schema 类型
- `.string`：纯字符串
- `.int`：整数（底层用 `CFGetTypeID==CFNumberGetTypeID()` 排除 `__NSCFBoolean` 桥接污染）
- `.bool`：布尔（底层用 `CFGetTypeID==CFBooleanGetTypeID()` 精确识别）
- `.numberOrString`：数字或数字字符串（如 `timeoutMs`，兼容 `15000` 与 `"15000"` 两种输入）

## 4b) 命令执行沙箱与审批升级链路

所有命令执行（前台 `BashTool`、`BackgroundTaskManager` 后台任务、subagent 工具链）统一经 `ProcessRunner` + `SandboxTransform` 包装，无裸奔通道。安全职责在 OS 沙箱（seatbelt），`ShellCommandAuditor` 已移除，`bash` 工具无 `args` 时经 `/bin/sh -c` 执行，管道/重定向/复合命令等完整 shell 能力放开。

### 默认策略与构造校验
- 默认 profile：`workspaceWrite(writableRoots: [cwd])` + `network: .disabled`（对齐 Codex 默认 workspace-write 断网）。
- `SandboxProfileFactory`（位于 `CodingAgentBuilder.swift`，调用方而非纯函数层做策略校验）：writable root 必须存在、为目录、非 symlink、不含控制字符（防 sbpl 注入）；全部拒绝时降级 `readOnly`；拒绝项经 `Diagnostics.log` 记录。
- 配置口子（`CodingAgentConfig`）：`sandboxProfile`（可切 `fullAccess`）、`approvalPolicy`、`escalationHandler`。

### 审批升级链路（对齐 Codex exec.rs 两段式）
1. 沙箱内命令失败，`SandboxDenialHeuristic` 判定疑似沙箱拒绝（非零退出 + stderr 含 `Operation not permitted`；curl exit 6 类网络拒绝 v1 不触发）。
2. `policy == .onFailure` 且存在 `escalationHandler` → 调 handler（带命令与拒绝原因）。
3. 批准 → `ProcessRunner(profile: nil)` 非沙箱重跑一次（直调不递归，结构上保证仅一次）；拒绝 / handler 缺失 → 原失败结果回灌模型并附 `[sandbox]` 提示。
4. CLI 审批 UI：`CodingTUISession` 复用 ListPicker 交互形态（`允许一次 / 拒绝`，默认落"拒绝"，Esc=拒绝），经 `SandboxApprovalBridge` 阻塞等待用户输入；仅交互式 TTY 注入 handler（非 TTY 与 AppKit 默认 handler=nil，等价 never，fail-closed）。
5. 等待后与重跑后均复查 cancellation，不破坏事件闭环。

### 语义注记（Review 移交，长期有效）
- **subagent 沙箱语义**：实际是 `childConfig.sandboxProfile override ?? SandboxProfileFactory.makeDefault(childCwd)`，**并非字面透传父 profile**——父 `fullAccess` 不会泄漏给子（fail-closed），对齐 Codex"对父的批准不构成对子的一般许可"。
- **已知限制**：代码路径 abort 不会 resume 挂起的审批 continuation（bash 调用悬置直至用户操作）；用户 Esc 路径已覆盖"abort 可中断等待"。
- **验证边界**：网络断网语义的端到端验证仅有 spike 层证据（本机代理 env 透传会污染判定，集成测试豁免网络项）；文件写拒绝特征（exit 1 + `Operation not permitted`）有集成测试覆盖。

## 5) 全局不变量
- 每条 assistant 回复事件闭环：
  - `messageStart -> messageUpdate* -> messageEnd`（旧）
  - 等价于 `blockStart -> blockUpdate* -> blockEnd`（新）
- 终止语义一致：
  - 正常：`.done` + `end(final)`
  - 失败：`.error` + `end(errorMessage)`
  - 取消：`.error(reason: .aborted)` + `end(abortedMessage)` 且不再 `.done`
- 单次只允许一个 active run（防重入）。

## 6) 并发模型与约束（Swift 6）
- 默认优先：结构化并发（`async/await`、`TaskGroup`、actor）。
- UI 相关状态使用 `@MainActor`，非 UI 逻辑禁止滥用 `@MainActor`。
- 长耗时流程必须支持取消并及时响应取消。
- 如需 `@unchecked Sendable`，必须说明安全不变量：
  - 所有可变共享状态是否由锁或 actor 严格保护；
  - 生命周期是否有明确边界；
  - 是否存在跨线程逃逸引用。

## 7) 扩展规则
- 新增 provider：
  - 必须对齐现有 `AssistantMessageEvent` 语义。
- 新增 tool：
  - 必须通过 `ToolExecutor` 统一接入；
  - 必须产出可注入的 `ToolResultMessage`；
  - 必须提供错误语义与最小测试覆盖。
- 新增 UI 渲染行为：
  - 不可破坏 streaming 覆盖替换；
  - tool block 必须可定位替换，避免重复 append。
