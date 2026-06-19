# P3 规划：工程化 + 全量 Trace

> 日期：2026-06-19
> 状态：已封存，待执行
> 协作模式：AI 负责总体规划与评审，用户负责实现（参见 `COLLABORATION.md`）

---

## 1. 背景与目标

P0–P2 已完成，v0.3.0 已发布。P3 进入工程化与可观测性建设阶段，核心目标是建立**全量 trace 工程**，为后续功能迭代和问题排查提供可观测基础。

### 1.1 当前状态

- 代码中无任何日志/可观测性框架，仅 3 处 `print`。
- `AgentEvent` 已是跨层事件总线，天然适合作为 trace 主干。
- `SessionStore` 已支持命名会话，但 CLI 缺少全局会话切换 UI。
- Provider 层无重试、统一错误 taxonomy、日志/可观测性、路由/fallback。
- AppKit 无独立测试 target。
- CI 无 lint、无自动 release；`PerformanceGateTests` 在 nightly 中 non-blocking。

### 1.2 P3 目标

- 建立跨层统一可观测性基础设施，覆盖 **Provider → SSE → Agent → Tool → Subagent → CLI → AppKit** 全链路。
- 接入 SwiftLint / SwiftFormat，统一代码风格。
- 将已有 `PerformanceGateTests` 接入 CI workflow。

---

## 2. 设计原则

1. **分层依赖 `ForgeLoopDiagnostics`**，不跨层直接耦合。
2. **Trace 与 Log 分离**：Trace 管 span 链路，Log 管时间序列状态/异常。
3. **不破坏事件闭环**：trace 只读观察，不修改 `AgentEvent` 语义。
4. **默认零开销**：未启用时编译期和运行期均为 NoOp。
5. **敏感信息脱敏**：API key、消息内容默认遮蔽；home 目录替换为 `~`。
6. **不侵入纯协议解析器**：`SSEParser` 保持零依赖，Provider 层记录解析事件。

---

## 3. 新增 Target：`ForgeLoopDiagnostics`

```
Sources/ForgeLoopDiagnostics/
├── Core/
│   ├── TraceContext.swift           // traceID / spanID / parentSpanID
│   ├── TraceLevel.swift             // debug / info / warn / error
│   ├── TraceAttribute.swift         // string / int / bool / double / masked
│   ├── TraceError.swift             // 错误模型
│   └── TraceIDGenerator.swift       // UUID / 时间序列 ID
├── Trace/
│   ├── TraceSystem.swift            // startSpan / endSpan / withSpan
│   ├── NoOpTraceSystem.swift        // 默认零开销实现
│   └── TraceSpan.swift              // span 事件模型
├── Log/
│   ├── LogSystem.swift              // log(level:message:attributes:)
│   ├── NoOpLogSystem.swift          // 默认零开销实现
│   ├── ConsoleLogSink.swift         // stderr 输出
│   ├── FileLogSink.swift            // 文件输出，10MB 滚动，保留 3 个
│   └── SensitiveDataMasker.swift    // 脱敏
└── Diagnostics.swift                // 统一门面
```

### 3.1 核心协议

```swift
public protocol TraceSystem: Sendable {
    func startSpan(
        name: String,
        parent: TraceContext?,
        layer: String,
        operation: String,
        attributes: [String: TraceAttribute]
    ) -> TraceContext

    func endSpan(
        _ context: TraceContext,
        attributes: [String: TraceAttribute],
        error: TraceError?
    )
}

public protocol LogSystem: Sendable {
    func log(
        level: TraceLevel,
        message: String,
        attributes: [String: TraceAttribute]
    )
}
```

### 3.2 TraceContext 跨层传播

| 层级 | 载体 | 创建 span 的位置 |
|---|---|---|
| CLI/App | 调用入口 | `SessionCoordinator.submit()` 创建 root span |
| Agent | `AgentLoopConfig.traceContext` | `AgentLoop.run()` 创建 child span |
| AI | `StreamOptions.traceContext` | `HTTPClient.stream()` / Provider 创建 child span |
| Tool | `ToolExecutor` | `ToolExecutor.execute()` 创建 tool_call span |
| Subagent | `AgentLoopConfig.traceContext` | `SubagentTool` 以 tool_call span 为 parent 创建子 agent span |

### 3.3 高频事件采样

- `messageUpdate` / `blockUpdate` 等 token 级事件：**仅在 `TraceLevel.debug` 记录**。
- `ConsoleLogSink` 对 debug 事件做 rate limiting：同 span + 同 operation 每秒最多 1 条。
- `FileLogSink` 默认保留全部 debug 事件。

---

## 4. 分层接入点

| 层级 | 接入点 | 记录内容 | 级别 |
|---|---|---|---|
| **ForgeLoopAI** | `APIRegistry.stream/complete` | 请求开始、provider 选择、模型元信息 | info |
| | `HTTPClient.stream` | method、URL、status、duration、网络错误 | info / error |
| | 各 Provider | SSE 解析事件、provider-specific 错误体、tool_call 解析 | debug / error |
| **ForgeLoopAgent** | `AgentLoop.run` | 每轮开始/结束、turn 数、是否触发 tool | info |
| | `Agent.prompt/steer/cancel/abort` | 用户输入、steer、取消原因 | info |
| | `ToolExecutor.register` | 工具名、注册时间、可用工具列表 | debug |
| | `ToolExecutor.execute` | 工具调用开始/结束/错误、参数摘要 | info / error |
| | `AgentEvent` 总线 | 所有 `AgentEvent` | debug |
| | `SubagentTool.execute` / `runSubagent` | 子 agent 创建，以 tool_call span 为 parent | info |
| **ForgeLoopCli** | `SessionCoordinator.submit` | 创建 root span | info |
| | `SessionCoordinator.switchModel` | 模型切换 | info |
| | `SessionCoordinator.save/load` | 会话保存/恢复 | info |
| | `PromptController` | 输入接收、队列状态 | debug |
| | `CodingTUI` / `TranscriptRenderer` | 渲染模式切换（低频） | debug |
| **ForgeLoopApp** | `AppController` | 窗口/标签生命周期、模型选择器切换 | info |
| | `TabSession` | 标签创建/关闭/恢复 | info |

---

## 5. P3 Step 拆分

| Step | 目标 | 主要改动文件 | 验证命令 | 风险点 |
|---|---|---|---|---|
| **STEP-030** | 接入 SwiftLint + SwiftFormat | `.swiftlint.yml`、`.swiftformat`、`.github/workflows/ci.yml` | `swift build && swift test` + lint | 首次格式化 diff 大 |
| **STEP-031** | 创建 `ForgeLoopDiagnostics` target + Trace/Log 协议 | `Package.swift`、新增 `Sources/ForgeLoopDiagnostics/**/*.swift` | `swift build` | target 依赖循环；Sendable 合规 |
| **STEP-032** | 实现 Console/File LogSink + 脱敏 | `ConsoleLogSink.swift`、`FileLogSink.swift`、`SensitiveDataMasker.swift` | `swift test --filter Diagnostics` | 文件滚动、并发写、脱敏 |
| **STEP-033** | ForgeLoopAI 层 trace 接入 | `Context.swift`、`APIRegistry.swift`、`HTTPClient.swift`、各 Provider | `swift test --filter AI` | 高频 SSE 事件控制；不侵入 SSEParser |
| **STEP-034** | ForgeLoopAgent 层 trace 接入 | `AgentTypes.swift`、`Agent.swift`、`AgentLoop.swift`、`ToolExecutor.swift`、`SubagentTool.swift`、`SubagentRunner.swift` | `swift test --filter Agent` | Subagent 嵌套 span；并发安全 |
| **STEP-035** | ForgeLoopCli + ForgeLoopApp trace 接入 | `SessionCoordinator.swift`、`PromptController.swift`、`CodingTUI.swift`、`AppController.swift`、`TabSession.swift`、两个 `main.swift` | 手动运行 CLI/App 验证 trace 输出 | AppKit 生命周期与 trace 关闭顺序 |
| **STEP-036** | PerformanceGate 接入 CI workflow | `.github/workflows/ci.yml`、`.github/workflows/nightly.yml` | CI 全绿 3 次 | runner 噪声误报 |

---

## 6. CLI / AppKit 启用方式

### CLI

```bash
forgeloop --trace-level debug --trace-file ~/.config/forgeloop/trace.log
# 或
FORGELOOP_TRACE_LEVEL=debug FORGELOOP_TRACE_FILE=... forgeloop
```

### AppKit

- UserDefaults：`ForgeLoopAppTraceEnabled`、`ForgeLoopAppTraceFilePath`、`ForgeLoopAppTraceLevel`
- 菜单项：Debug → Enable Trace

---

## 7. 验证方式

1. `swift test` 全绿。
2. 新增 `DiagnosticsTests`、`FileLogSinkTests`、`SensitiveDataMaskerTests`、`SubagentTraceTests`。
3. CLI 运行一次真实对话，检查 trace 文件完整且无敏感信息。
4. `PerformanceGateTests` 无回归。

---

## 8. 风险汇总

1. debug 级 token 事件仍可能刷爆日志，需 rate limit。
2. 脱敏策略遗漏导致 API key 泄露。
3. `TraceContext` 跨层传递需保证 `Sendable` 合规。
4. Subagent 嵌套 span 生命周期需与取消传播对齐。
5. GitHub Actions runner 性能噪声导致 PerformanceGate 误报。

---

## 9. P3 Backlog（非阻塞，核心 step 完成后处理）

1. **FauxProvider span 结束顺序统一**
   - 当前 FauxProvider 在 `output.end(final)` 之后结束 span，与其他 Provider 在 `output.end` 之前结束 span 的顺序不一致。
   - 不影响功能，P3 核心 step 完成后再统一。

2. **SensitiveDataMasker actor → struct**
   - 当前 masker 是无状态 actor，所有调用点需要 `await`。
   - 可改为 struct + `nonisolated` 方法，减少调用点噪音。
   - 需在 STEP-035 各层接入完成后再改，避免接口 ripple。

## 10. 远期备注

- **Liquid Glass 适配**：AppKit 层若未来做 trace viewer，需考虑 macOS 26 的 Liquid Glass 设计语言。不纳入 P3。
- **OTLP / Zipkin exporter**：在 `ForgeLoopDiagnostics` 中预留 exporter 协议，未来扩展。
