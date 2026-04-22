# KWWK 复刻计划（Swift）

## 目标
以 Swift 复刻一个与 KWWK 功能一致的项目，重点确保：
- Harness Agent 架构与行为一致；
- TUI 流式输出机制一致；
- 工具调用与上下文顺序一致；
- streaming 期间可继续输入并排队执行。

---

## 一、功能一致性范围（Scope）

### 1) 必须一致（MVP 必达）
- 模块分层一致：
  - `ForgeLoopAI`：Provider、HTTP 流、SSE 解析、消息流抽象
  - `ForgeLoopAgent`：Agent 状态机、回合循环、工具执行、队列与取消
  - `ForgeLoopCli`：TUI 运行时、渲染、输入绑定、流式 transcript
- 事件驱动链路一致：
  - Provider SSE → `AssistantMessageEvent` → `AgentEvent.messageUpdate` → TUI 覆盖刷新
- 工具回合一致：
  - assistant tool_call 先入 transcript/context，再执行 tool，再注入 tool_result
- 用户交互一致：
  - Enter（idle=prompt / streaming=steer）
  - Esc（streaming=abort / idle+bg=killAll）
  - Ctrl-C（退出）

### 2) 第二阶段补齐（非首发必需）
- OAuth 登录流程
- `/model`、`/compact`、附件与粘贴增强
- 更多 provider 适配

---

## 二、目标架构（推荐与原项目等价）

## 1) `Sources/ForgeLoopAI`
- `APIProvider` / `APIRegistry`
- `HTTPClient`（`URLSession.bytes(for:)`）
- `SSEParser`
- `AssistantMessageStream`（`AsyncSequence + result()`）
- Provider:
  - `OpenAIResponsesProvider`
  - `AnthropicProvider`
  - `FauxProvider`（测试与回归）

## 2) `Sources/ForgeLoopAgent`
- `AgentState`（线程安全快照状态）
- `Agent`（生命周期、订阅、并发互斥、取消）
- `AgentLoop`（无状态回合驱动）
- `AgentEvent` / `ToolExecutionMode`
- 工具集合（`read/write/edit/bash/find/grep/ls/bg_status`）
- `BackgroundTaskManager` + `Agent+Background` 桥接

## 3) `Sources/ForgeLoopCli`
- `TUIRunner`（raw stdin、keybinding、signal）
- `TUI`（ANSI 渲染与 frame 重绘）
- `TranscriptRenderer`（streamingRange 覆盖更新）
- `CodingTUI`（粘合层：订阅 agent 事件并驱动 UI）

---

## 三、Harness Agent 详细实现方案（重点）

## 1) 核心抽象
- `Agent`: 有状态 façade（对外 API）
- `AgentLoop`: 无状态 loop（纯回合逻辑）
- `AgentState`: 线程安全状态容器（messages/streaming/pendingTools/error）
- `AgentEvent`: 统一事件总线

## 2) 生命周期与并发控制
- `runLifecycle()` 负责：
  - 防重入（alreadyRunning）
  - 建立 cancellation handle
  - 状态切换（isStreaming true/false）
  - 失败兜底（error/aborted）
  - 结束清理（pendingToolCalls、waiters）

## 3) 回合循环（必须对齐的行为）
- 输入 prompts 后进入 `runLoop`
- 每个 turn：
  1. 注入 steering queue
  2. 流式拉取 assistant（messageStart/messageUpdate/messageEnd）
  3. 解析 tool calls
  4. 执行 tools（顺序或并行）
  5. 注入 tool_result
  6. turnEnd
- **关键顺序约束（必须保真）**：
  - assistant(tool_call) 必须先 append 到 context，再执行 tool。
  - 保证下一轮请求体顺序：`[user, assistant(tool_call), tool_result]`。

## 4) 队列机制（streaming 输入不断流）
- `steeringQueue`: 当前 run 的 turn 边界注入消息
- `followUpQueue`: 将在 loop 将停时触发的后续消息
- streaming 期间的 Enter：不直接 `prompt()`，改为 `steer(.user(...))`

## 5) 工具执行模式
- `sequential`: 严格串行执行
- `parallel`: 并发执行 + 源顺序收敛结果
- 支持 `toolExecutionUpdate`（可选实时进度）
- end 前等待 update 发完，避免 UI 先 end 后 update 的错序

## 6) 背景任务桥接
- `BackgroundTaskManager` 跟踪 bg task + 通知 FIFO 投递
- `Agent+Background` 监听通知并转成 synthetic user message
- idle 时触发 `continue()`，busy 时由 steering queue 在 turn 边界被消费

---

## 四、TUI 流式输出实现方案（重点）

## 1) 渲染模型
- Transcript 不是 append-only，而是“append + 覆盖”：
  - `streamingRange` 标记当前 assistant 流式占据区间
  - 每次 `messageUpdate` 用 `replaceStreaming()` 覆盖该区间
  - `messageEnd` 时冻结并清空 `streamingRange`

## 2) tool block 可读性策略
- `toolExecutionStart`：
  - 显示 `● tool(args)`
  - 下一行 `⎿ running...`
- `toolExecutionEnd`：
  - 替换 running 行为结果预览
  - 长输出截断 + hidden lines 提示

## 3) TUI 刷新机制
- `agent.subscribe` 里：
  - `renderer.apply(event)`
  - `layout.setTranscript(...)`
  - `tui.requestRender()`
- `TUI.renderInline` 负责 ANSI 重绘：
  - 回退到 frame 顶
  - 清旧内容
  - 写新 frame
  - 复位光标到输入位置

## 4) 输入处理
- `TUIRunner` 处理 raw stdin + key event
- 处理 ESC 延迟 flush（解决单独 ESC 被 CSI 吞并）
- keybinding：Enter/Esc/Ctrl-C/上下键（modal）

---

## 五、分阶段实施计划（执行顺序）

## Phase 1：内核与测试先行
- 建立 SPM 工程与三模块目录
- 完成：
  - `AssistantMessageStream`
  - `SSEParser`
  - `APIRegistry`
  - `AgentState` / `Agent` / `AgentLoop`
  - `FauxProvider`
- 测试：
  - 生命周期事件顺序
  - abort 行为
  - tool_call 上下文顺序
  - steering/follow-up 队列行为

## Phase 2：工具与后台任务
- 完成：`read/write/edit/bash/find/grep/ls/bg_status`
- 完成：`BackgroundTaskManager` + bridge
- 测试：
  - 并行与串行工具执行
  - bg 通知注入对话
  - killAll 与 session 过滤

## Phase 3：TUI 与流式渲染
- 完成：`TUIRunner` / `TUI` / `TranscriptRenderer` / `CodingTUI`
- 打通：AgentEvent → Renderer → requestRender
- 测试：
  - streamingRange 覆盖稳定
  - tool block 占位替换
  - resize 全量重绘与 shrink 清理

## Phase 4：体验补齐
- OAuth 登录与 auth resolver
- `/model`、`/compact`、附件粘贴
- 真实 provider 回归

---

## 六、测试策略（建议）

## 1) 单元测试（高优先）
- `AgentLoop`：
  - 事件顺序
  - tool_call / tool_result 顺序
  - parallel 模式不打乱结果顺序
- `TranscriptRenderer`：
  - messageUpdate 覆盖逻辑
  - tool running→result 替换逻辑
- `SSEParser`：
  - 分块边界、末尾 finish、注释行

## 2) 集成测试
- FauxProvider 端到端：prompt→tool→final
- streaming 中 steer 多条消息并依序执行
- abort 中断恢复可继续 prompt

## 3) 手工验收
- 连续长文本 streaming 无重复/抖动
- 长命令自动进后台并收到通知
- Esc/Ctrl-C 行为符合预期

---

## 七、风险与规避
- 风险：tool_call 顺序错误导致 provider 报错
  - 规避：assistant(tool_call) 先 append context 再执行 tool
- 风险：UI 闪烁/重复行
  - 规避：streamingRange 覆盖替换，不做纯 append
- 风险：并发状态竞争
  - 规避：Agent 只允许一个 active run，状态走锁保护
- 风险：通知乱序
  - 规避：BackgroundTaskManager 用 FIFO deliveryQueue 串行投递

---

## 八、完成定义（Definition of Done）
- 能在 Swift CLI 内稳定复现：
  - Agent 回合 + 工具调用 + 流式消息
  - streaming 输入排队（steer）
  - TUI 覆盖刷新与工具结果替换
  - abort / bg task / 通知注入
- 核心测试全部通过（Agent/AI/CLI 三层）。

---

## 九、建议的下一步（立即执行）
1. 先搭建三模块 SPM skeleton。
2. 优先实现 `AssistantMessageStream` + `AgentLoop` + FauxProvider。
3. 先跑通“无 UI 的端到端”，再接 TUI。
4. 最后补 OAuth 与 slash commands。

