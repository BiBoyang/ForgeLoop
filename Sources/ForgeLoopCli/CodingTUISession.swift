import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI
import ForgeLoopDiagnostics
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        agent = await makeCodingAgent(
            CodingAgentConfig(model: model, cwd: cwd),
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
            modelStore.save(agent.state.model)
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
