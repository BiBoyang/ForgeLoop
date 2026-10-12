import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI
import ForgeLoopDiagnostics
import ForgeLoopSandbox
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 进行中的沙箱升级审批：picker 状态 + 等待中的 continuation。
struct ApprovalPrompt {
    var picker: ListPickerState
    let continuation: CheckedContinuation<Bool, Never>
}

/// 审批桥：解决 session 初始化顺序——agent（及其 BashTool 的 escalationHandler）
/// 必须先于 session 构造完成创建，handler 通过桥间接到达 session。
///
/// `@unchecked Sendable` 安全不变量：
/// - 仅持有对 session 的弱引用，且在 MainActor 上于 session init 末尾一次性写入
///   （写入发生在 agent 运行任何 bash 之前，handler 不可能更早触发）；
/// - `request` 内部立即 `await` 跳到 MainActor 操作 UI 状态，
///   不在调用方执行域触碰任何可变状态。
final class SandboxApprovalBridge: @unchecked Sendable {
    @MainActor weak var session: CodingTUISession?

    func request(command: String, reason: String) async -> Bool {
        await requestOnMain(command: command, reason: reason)
    }

    @MainActor
    private func requestOnMain(command: String, reason: String) async -> Bool {
        guard let session else { return false }
        return await session.requestSandboxApproval(command: command, reason: reason)
    }
}

@MainActor
final class CodingTUISession {
    let agent: Agent
    let tui: TUI
    let renderer: TranscriptRenderer
    var renderLoop: RenderLoop?
    let attachmentStore: AttachmentStore
    let modelStore: ModelStore
    let sessionStore: SessionStore
    let pickerRenderer: ListPickerRenderer
    let diagnostics: Diagnostics

    var inputState = MultiLineInputState()
    var inputHistory = PromptHistory()
    var activeModelPicker: ListPickerState?
    var activeApproval: ApprovalPrompt?
    var queueLines: [String] = []
    var backgroundTaskSummary = BackgroundTaskSummary()
    var isAbortRequested = false
    var activeFooterNotice: FooterNotice?
    var didCompactRecently = false

    var hasPrintedStaticHeader = false
    var appendModeActive = false
    var transcriptAppendState = StreamingTranscriptAppendState()
    var currentAssistantBlockID: String?

    var lastTerminalSize: TerminalSize? = getTerminalSize()

    let controller: PromptController
    let keyResolver: KeyResolver<KeyAction>

    var bgMonitor: Task<Void, Never>?

    init(model: Model, cwd: String, diagnostics: Diagnostics = Diagnostics()) async {
        self.diagnostics = diagnostics
        let isInteractiveTTY = isatty(STDOUT_FILENO) == 1 && isatty(STDIN_FILENO) == 1
        tui = TUI(
            isTTY: isInteractiveTTY,
            liveBudget: 4,
            liveBudgetMode: .physicalRows,
            cursorPositioningMode: .marker
        )
        renderer = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())
        // 沙箱升级审批：仅交互式 TTY 注入 handler（非 TTY 无人应答会挂起，等价 never）。
        // 经 SandboxApprovalBridge 间接回跳本 session（init 顺序约束）。
        let approvalBridge = SandboxApprovalBridge()
        let escalationHandler: SandboxEscalationHandler?
        if isInteractiveTTY {
            escalationHandler = { command, reason in
                await approvalBridge.request(command: command, reason: reason)
            }
        } else {
            escalationHandler = nil
        }
        agent = await makeCodingAgent(
            CodingAgentConfig(model: model, cwd: cwd, escalationHandler: escalationHandler),
            diagnostics: diagnostics
        )
        modelStore = ModelStore()
        sessionStore = SessionStore()
        pickerRenderer = ListPickerRenderer()
        attachmentStore = AttachmentStore()

        // Auto-restore last session if it exists
        if let lastSession = try? sessionStore.load(name: "last"), !lastSession.messages.isEmpty {
            try? await agent.restoreSession(
                messages: lastSession.messages,
                modelID: lastSession.modelID
            )
            // 注意：不要把恢复出的模型 modelStore.save 回写——session 里残留的过期 modelID
            // 会借此污染用户当前的模型配置（2026-10-12 实测事故：faux 实验残留
            // "new-model-id" 经此路径反复覆写 deepseek 配置）。
        }

        controller = PromptController(
            agent: agent,
            modelStore: modelStore,
            attachmentStore: attachmentStore,
            sessionStore: sessionStore,
            diagnostics: diagnostics
        )
        keyResolver = KeyResolver(registry: makeKeybindings())

        let disableRenderLoop = ProcessInfo.processInfo.environment["FORGELOOP_TUI_RENDER_LOOP"] == "0"
        await diagnostics.log.log(
            level: .debug,
            message: "tui.render_mode",
            attributes: [
                "is_tty": .bool(isInteractiveTTY),
                "render_loop_disabled": .bool(disableRenderLoop)
            ]
        )
        renderLoop = disableRenderLoop
            ? nil
            : RenderLoop(render: { [tui] frame in
                tui.requestRender(lines: frame)
            })

        // 所有 stored properties 就绪后回接审批桥（agent 此刻尚未运行 bash，handler 不可能更早触发）
        approvalBridge.session = self

        _ = agent.subscribe { @MainActor [weak self] event, _ in
            guard let self else { return }

            let eventPriority: RenderLoop.Priority = {
                switch event {
                case .messageEnd, .agentEnd:
                    return .immediate
                default:
                    return .normal
                }
            }()

            switch event {
            case .messageStart(message: .assistant):
                currentAssistantBlockID = UUID().uuidString
            case .messageEnd(message: .assistant):
                currentAssistantBlockID = nil
            default:
                break
            }

            let blockID = currentAssistantBlockID ?? "__assistant"
            for coreEvent in toCoreRenderEvent(event, blockID: blockID) {
                renderer.applyCore(coreEvent)
            }

            if case .contextCompacted(let before, let after, _) = event {
                didCompactRecently = true
                let notice = FooterNotice(
                    text: "Auto-compacted context: \(before) → \(after) messages",
                    priority: .info
                )
                activeFooterNotice = resolveFooterNotice(current: activeFooterNotice, incoming: notice)
            }

            if !agent.state.isStreaming {
                isAbortRequested = false
            }

            renderFrame(priority: eventPriority)
        }
    }

    /// 阻塞等待用户审批沙箱升级请求。复用 ListPicker 交互形态（对齐 /model picker）。
    /// 同时只允许一个审批等待（单 active run + 顺序工具执行下本就不会并发，兜底拒绝）。
    func requestSandboxApproval(command: String, reason: String) async -> Bool {
        if activeApproval != nil { return false }
        return await withCheckedContinuation { continuation in
            let truncatedCommand = command.count > 100 ? String(command.prefix(100)) + "…" : command
            let picker = ListPickerState(
                title: "沙箱拒绝了这次命令，是否提升权限重跑？",
                subtitle: "\(truncatedCommand)\n原因: \(reason)",
                items: [
                    ListPickerItem(id: "allow", title: "允许一次", subtitle: "本次以非沙箱方式重跑（仅此一次）"),
                    ListPickerItem(id: "deny", title: "拒绝", subtitle: "按失败处理并回灌模型"),
                ],
                selectedIndex: 1, // 默认落在「拒绝」，安全优先
                footer: "(↑↓ 选择，Enter 确认，Esc 拒绝)"
            )
            activeApproval = ApprovalPrompt(picker: picker, continuation: continuation)
            renderFrame(priority: .immediate)
        }
    }

    func saveLastSession() {
        let msgs = agent.state.messages
        if !msgs.isEmpty {
            try? sessionStore.save(name: "last", modelID: agent.state.model.id, messages: msgs)
        }
    }

    func outputFrame(_ frame: ComposedFrame, priority: RenderLoop.Priority) {
        if let renderLoop, shouldCoalesceWithRenderLoop(frame: frame, priority: priority) {
            renderLoop.submit(frame: frame.committed, priority: .normal)
            return
        }
        // Keep a single frame-oriented render path so future live-region frames
        // are not accidentally flattened to committed-only output.
        tui.render(frame: frame)
    }
}
