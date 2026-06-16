import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 根据模型生成显示标签（纯函数，可测试）
func labelForModel(_ model: Model) -> String {
    if model.id == "faux-coding-model" {
        return "faux-coding-model · local scaffold"
    }
    return "\(model.name) (\(model.id))"
}

public func forgeLoopMarkdownRenderOptions() -> MarkdownRenderOptions {
    MarkdownRenderOptions(
        tablePolicy: TableRenderPolicy(
            maxRenderedWidth: 80,
            minColumnWidth: 4,
            maxColumnWidth: 28,
            truncationIndicator: "...",
            overflowBehavior: .compactThenTruncateThenDegrade
        )
    )
}

enum CodingStatusPhase: Sendable, Equatable {
    case ready
    case generating
    case aborting
    case selectingModel
    case runningBackgroundTasks
}

struct BackgroundTaskSummary: Sendable, Equatable {
    var runningCount: Int = 0
    var successCount: Int = 0
    var failedCount: Int = 0
    var cancelledCount: Int = 0
}

struct CodingStatusSnapshot: Sendable, Equatable {
    let modelLabel: String
    let phase: CodingStatusPhase
    let pendingToolCount: Int
    let queuedMessageCount: Int
    let attachmentCount: Int
    let backgroundTasks: BackgroundTaskSummary
    let didCompactRecently: Bool
}

func summarizeBackgroundTasks(_ tasks: [BackgroundTaskRecord]) -> BackgroundTaskSummary {
    var summary = BackgroundTaskSummary()
    for task in tasks {
        switch task.status {
        case .running:
            summary.runningCount += 1
        case .success:
            summary.successCount += 1
        case .failed:
            summary.failedCount += 1
        case .cancelled:
            summary.cancelledCount += 1
        }
    }
    return summary
}

func resolveStatusPhase(
    isStreaming: Bool,
    isAborting: Bool,
    isSelectingModel: Bool,
    hasRunningBackgroundTasks: Bool
) -> CodingStatusPhase {
    if isSelectingModel {
        return .selectingModel
    }
    if isAborting {
        return .aborting
    }
    if isStreaming {
        return .generating
    }
    if hasRunningBackgroundTasks {
        return .runningBackgroundTasks
    }
    return .ready
}

func makeStatusLines(snapshot: CodingStatusSnapshot) -> [String] {
    let phaseText: String
    switch snapshot.phase {
    case .ready:
        phaseText = Style.success("● ready")
    case .generating:
        phaseText = Style.running("● generating")
    case .aborting:
        phaseText = Style.warning("● aborting")
    case .selectingModel:
        phaseText = Style.running("● selecting model")
    case .runningBackgroundTasks:
        phaseText = Style.running("● background tasks")
    }

    var lines = ["\(phaseText) \(Style.dimmed("model: \(snapshot.modelLabel)"))"]

    var badges: [String] = []
    if snapshot.pendingToolCount > 0 {
        badges.append("\(snapshot.pendingToolCount) tool\(snapshot.pendingToolCount == 1 ? "" : "s") pending")
    }
    if snapshot.queuedMessageCount > 0 {
        badges.append("\(snapshot.queuedMessageCount) queued")
    }
    if snapshot.attachmentCount > 0 {
        badges.append("\(snapshot.attachmentCount) attachment\(snapshot.attachmentCount == 1 ? "" : "s")")
    }
    if snapshot.backgroundTasks.runningCount > 0 {
        badges.append("\(snapshot.backgroundTasks.runningCount) bg running")
    }
    if snapshot.backgroundTasks.failedCount > 0 {
        badges.append("\(snapshot.backgroundTasks.failedCount) bg failed")
    }
    if snapshot.backgroundTasks.cancelledCount > 0 {
        badges.append("\(snapshot.backgroundTasks.cancelledCount) bg cancelled")
    }
    if snapshot.didCompactRecently {
        badges.append("compacted")
    }

    if !badges.isEmpty {
        lines.append(Style.dimmed(badges.joined(separator: " • ")))
    }

    return lines
}

/// 生成输入区 lines。附件提示放在输入行上方；第一行加 prompt 前缀 "❯ "，
/// 后续行用 "  " 对齐，保证光标锚点落在输入区最后一行。
func makeInputLines(inputLines: [String], attachmentCount: Int) -> [String] {
    guard !inputLines.isEmpty else { return [] }
    let prompt = "❯ "
    let continuation = "  "
    var result: [String] = []
    if attachmentCount > 0 {
        result.append(Style.dimmed("  \(attachmentCount) attachment\(attachmentCount == 1 ? "" : "s")"))
    }
    for (idx, line) in inputLines.enumerated() {
        result.append(idx == 0 ? prompt + line : continuation + line)
    }
    return result
}

func makeFooterNoticeLines(_ text: String) -> [String] {
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else { return [] }

    return lines.enumerated().map { index, line in
        if index == 0 {
            return Style.warning("▸ \(line)")
        }
        return Style.dimmed(line)
    }
}

// MARK: - Footer Notice

/// Footer notice 的统一封装，用于管理 status bar 下方的临时反馈。
///
/// 职责边界（三者不可混淆）：
/// - Status bar（状态栏）= 持续状态：model、phase、badges（attachment count、queued count 等）。
///   始终可见，反映当前运行态，不由用户命令直接写入。
/// - Footer notice（底部通知）= 临时反馈：/compact、/attach、auto-compact 等一次性提示。
///   用户输入或新提交时自动清除。
/// - Transcript（对话区）= 真正对话内容：用户消息和 AI 回复。
///   slash 命令的反馈绝不塞入 transcript。
///
/// 替换规则：
/// - 新 notice 优先级 >= 旧 notice 时覆盖
/// - 当前无 notice 时直接接受
/// - 用户任何输入操作（打字、删除、移动光标等）清除所有 notice
/// - .submitted（提交成功）清除所有 notice
struct FooterNotice: Equatable {
    let lines: [String]
    let priority: Priority

    enum Priority: Int, Comparable {
        case info = 0      // auto-compact 等自动触发
        case command = 1   // slash 命令反馈 (/queue, /attachments, /compact 等)
        case error = 2     // 错误提示

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    init(text: String, priority: Priority) {
        self.lines = makeFooterNoticeLines(text)
        self.priority = priority
    }
}

/// 决定是否用新 notice 替换当前 notice。
/// 规则：新优先级 >= 旧优先级时替换；当前无 notice 时直接接受。
func resolveFooterNotice(current: FooterNotice?, incoming: FooterNotice) -> FooterNotice {
    guard let current = current else { return incoming }
    return incoming.priority >= current.priority ? incoming : current
}

// MARK: - KeyAction

/// 输入层按键动作抽象，避免 CodingTUI 主循环直接膨胀 KeyEvent 分支。
public enum KeyAction: Sendable, Equatable {
    case insert(Character)
    case delete
    case deleteForward
    case submit
    case insertNewline
    case cancel
    case exit
    case historyPrev
    case historyNext
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case moveToLineStart
    case moveToLineEnd
    case moveToBufferStart
    case moveToBufferEnd
    case killToLineStart
    case killToLineEnd
    case paste(String)
    case newTab
    case closeTab
    case ignore
}

enum EscapeIntent: Sendable, Equatable {
    case abortStreaming
    case killBackgroundTasks
    case clearInput
}

func resolveEscapeIntent(isStreaming: Bool, hasRunningBackgroundTasks: Bool) -> EscapeIntent {
    if isStreaming {
        return .abortStreaming
    }
    if hasRunningBackgroundTasks {
        return .killBackgroundTasks
    }
    return .clearInput
}

public func makeKeybindings() -> KeybindingRegistry<KeyAction> {
    var registry = KeybindingRegistry<KeyAction>()
    func bind(_ sequence: KeySequence, _ action: KeyAction) {
        do {
            try registry.register(sequence, action: action)
        } catch {
            assertionFailure("keybinding registration failed: \(error)")
        }
    }

    bind(KeySequence(KeyStroke(key: .enter)), .insertNewline)
    bind(KeySequence(KeyStroke(key: .backspace)), .delete)
    bind(KeySequence(KeyStroke(key: .delete)), .deleteForward)
    bind(KeySequence(KeyStroke(key: .left)), .moveLeft)
    bind(KeySequence(KeyStroke(key: .right)), .moveRight)
    bind(KeySequence(KeyStroke(key: .up)), .moveUp)
    bind(KeySequence(KeyStroke(key: .down)), .moveDown)
    bind(KeySequence(KeyStroke(key: .home)), .moveToLineStart)
    bind(KeySequence(KeyStroke(key: .end)), .moveToLineEnd)
    bind(KeySequence(KeyStroke(key: .escape)), .cancel)

    // readline-style control-letter bindings (KeyParser emits uppercase letters
    // for Ctrl- combos, so register the uppercase form).
    bind(KeySequence(KeyStroke(key: .character("A"), modifiers: .ctrl)), .moveToLineStart)
    bind(KeySequence(KeyStroke(key: .character("E"), modifiers: .ctrl)), .moveToLineEnd)
    bind(KeySequence(KeyStroke(key: .character("U"), modifiers: .ctrl)), .killToLineStart)
    bind(KeySequence(KeyStroke(key: .character("K"), modifiers: .ctrl)), .killToLineEnd)
    bind(KeySequence(KeyStroke(key: .character("P"), modifiers: .ctrl)), .historyPrev)
    bind(KeySequence(KeyStroke(key: .character("N"), modifiers: .ctrl)), .historyNext)
    bind(KeySequence(KeyStroke(key: .character("O"), modifiers: .ctrl)), .insertNewline)
    bind(KeySequence(KeyStroke(key: .character("J"), modifiers: .ctrl)), .submit)
    bind(KeySequence(KeyStroke(key: .character("C"), modifiers: .ctrl)), .exit)
    bind(KeySequence(KeyStroke(key: .character("T"), modifiers: .command)), .newTab)
    bind(KeySequence(KeyStroke(key: .character("W"), modifiers: .command)), .closeTab)

    return registry
}


private struct FooterRenderState {
    let inputLines: [String]
    let frame: ComposedFrame
    let cursorPlacement: CursorPlacement?
}

func shouldCoalesceWithRenderLoop(
    frame: ComposedFrame,
    priority: RenderLoop.Priority
) -> Bool {
    priority == .normal && frame.live.isEmpty && frame.cursorOffset == nil && frame.cursorPlacement == nil
}

@MainActor
func runCodingTUIInternal(
    model: Model,
    cwd: String
) async throws {
    let isInteractiveTTY = isatty(STDOUT_FILENO) == 1 && isatty(STDIN_FILENO) == 1
    let tui = TUI(
        isTTY: isInteractiveTTY,
        liveBudget: 4,
        liveBudgetMode: .physicalRows,
        cursorPositioningMode: .marker
    )
    let renderer = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())
    let agent = await makeCodingAgent(CodingAgentConfig(model: model, cwd: cwd))
    let modelStore = ModelStore()
    let sessionStore = SessionStore()
    let pickerRenderer = ListPickerRenderer()

    // Auto-restore last session if it exists
    if let lastSession = try? sessionStore.load(name: "last"), !lastSession.messages.isEmpty {
        agent.state.messages = lastSession.messages
        if lastSession.modelID != agent.state.model.id {
            agent.state.model = switchedModel(from: agent.state.model, to: lastSession.modelID)
            modelStore.save(agent.state.model)
        }
    }

    func saveLastSession() {
        let msgs = agent.state.messages
        if !msgs.isEmpty {
            try? sessionStore.save(name: "last", modelID: agent.state.model.id, messages: msgs)
        }
    }
    let keyResolver = KeyResolver(registry: makeKeybindings())

    let disableRenderLoop = ProcessInfo.processInfo.environment["FORGELOOP_TUI_RENDER_LOOP"] == "0"
    let renderLoop: RenderLoop? = disableRenderLoop
        ? nil
        : RenderLoop(render: { [tui] frame in
            tui.requestRender(lines: frame)
        })

    let outputFrame: @Sendable (ComposedFrame, RenderLoop.Priority) -> Void = { [tui, renderLoop] frame, priority in
        if let renderLoop, shouldCoalesceWithRenderLoop(frame: frame, priority: priority) {
            renderLoop.submit(frame: frame.committed, priority: .normal)
            return
        }
        // Keep a single frame-oriented render path so future live-region frames
        // are not accidentally flattened to committed-only output.
        tui.render(frame: frame)
    }
    var hasPrintedStaticHeader = false
    var appendModeActive = false
    var transcriptAppendState = StreamingTranscriptAppendState()
    var currentAssistantBlockID: String? = nil

    var inputState = MultiLineInputState()
    var inputHistory = PromptHistory()
    var activeModelPicker: ListPickerState?
    var queueLines: [String] = []
    var backgroundTaskSummary = BackgroundTaskSummary()
    var isAbortRequested = false
    var activeFooterNotice: FooterNotice? = nil
    var didCompactRecently = false
    var lastTerminalSize: TerminalSize? = getTerminalSize()


    func refreshQueueLines() async {
        if let bgManager = agent.backgroundTaskManager {
            let tasks = await bgManager.status()
            backgroundTaskSummary = summarizeBackgroundTasks(tasks)
            queueLines = tasks.map { task in
                let icon: String
                switch task.status {
                case .running: icon = "◉"
                case .success: icon = "✓"
                case .failed: icon = "✗"
                case .cancelled: icon = "⊘"
                }
                return "\(icon) [\(task.id)] \(task.command)"
            }
        } else {
            backgroundTaskSummary = BackgroundTaskSummary()
            queueLines = []
        }
    }

    func makeFooterRenderState(
        statusLines: [String],
        config: ScreenLayoutConfig
    ) -> FooterRenderState {
        if let activeModelPicker {
            let inputLines = pickerRenderer.render(state: activeModelPicker)
            let frame = CodingTUIFrameBuilder.build(input: .init(
                queueLines: queueLines,
                statusLines: (activeFooterNotice?.lines ?? []) + statusLines,
                inputLines: inputLines,
                terminalHeight: config.terminalHeight,
                terminalWidth: config.terminalWidth,
                showHeader: config.showHeader
            ))
            return FooterRenderState(inputLines: inputLines, frame: frame, cursorPlacement: nil)
        }

        // Soft-wrap aware viewport for moveUp/Down. The prompt "❯ " reserves
        // 2 visible cells on the first row, so usable wrap width is terminalWidth - 2.
        let viewportWidth = max(1, config.terminalWidth - 2)
        if inputState.viewport?.width != viewportWidth {
            inputState.setViewport(Viewport(width: viewportWidth))
        }

        let inputRender = inputState.render()
        let inputLines = makeInputLines(inputLines: inputRender.lines, attachmentCount: attachmentStore.count)
        let frame = CodingTUIFrameBuilder.build(input: .init(
            queueLines: queueLines,
            statusLines: (activeFooterNotice?.lines ?? []) + statusLines,
            inputLines: inputLines,
            terminalHeight: config.terminalHeight,
            terminalWidth: config.terminalWidth,
            showHeader: config.showHeader,
            cursorPlacement: inputRender.cursor
        ))
        return FooterRenderState(inputLines: inputLines, frame: frame, cursorPlacement: inputRender.cursor)
    }

    func renderFrame(priority: RenderLoop.Priority = .normal) {
        let currentModel = agent.state.model
        let modelLabel = labelForModel(currentModel)
        let statusLines = makeStatusLines(
            snapshot: CodingStatusSnapshot(
                modelLabel: modelLabel,
                phase: resolveStatusPhase(
                    isStreaming: agent.state.isStreaming,
                    isAborting: isAbortRequested,
                    isSelectingModel: activeModelPicker != nil,
                    hasRunningBackgroundTasks: backgroundTaskSummary.runningCount > 0
                ),
                pendingToolCount: renderer.pendingToolCount,
                queuedMessageCount: agent.queuedSteeringMessages().count,
                attachmentCount: attachmentStore.count,
                backgroundTasks: backgroundTaskSummary,
                didCompactRecently: didCompactRecently
            )
        )

        let size = getTerminalSize()
        if let last = lastTerminalSize, let current = size, last != current {
            tui.updateTerminalSize(width: current.columns, height: current.rows)
        }
        lastTerminalSize = size

        let config = ScreenLayoutConfig(
            terminalHeight: size?.rows ?? 24,
            terminalWidth: size?.columns ?? 80
        )
        let headerLines = [
            Style.header("✻ forgeloop replica"),
            Style.dimmed("  \(modelLabel)"),
            Style.dimmed("  \(cwd)"),
            "",
        ]
        let footerRender = makeFooterRenderState(
            statusLines: statusLines,
            config: config
        )

        guard tui.isTTY else {
            let frame = CodingTUIFrameBuilder.build(input: .init(
                headerLines: headerLines,
                transcriptLines: renderer.transcriptLines,
                queueLines: queueLines,
                statusLines: (activeFooterNotice?.lines ?? []) + statusLines,
                inputLines: footerRender.inputLines,
                pinnedTranscriptRange: renderer.preferredPinnedRange,
                terminalHeight: config.terminalHeight,
                terminalWidth: config.terminalWidth,
                showHeader: config.showHeader
            ))
            outputFrame(frame, priority)
            return
        }

        if !hasPrintedStaticHeader {
            tui.appendFrame(lines: headerLines)
            hasPrintedStaticHeader = true
        }

        if agent.state.isStreaming {
            if !appendModeActive {
                tui.requestRender(lines: [])
                appendModeActive = true
            }

            let appendedTranscriptLines = transcriptAppendState.consume(
                transcript: renderer.transcriptLines,
                activeRange: renderer.activeStreamingRange
            )
            if !appendedTranscriptLines.isEmpty {
                tui.appendFrame(lines: appendedTranscriptLines)
            }
            return
        }

        if appendModeActive {
            let remainingTranscriptLines = transcriptAppendState.consume(
                transcript: renderer.transcriptLines,
                activeRange: nil
            )
            if !remainingTranscriptLines.isEmpty {
                tui.appendFrame(lines: remainingTranscriptLines)
            }
            tui.resetRetainedFrame()
            appendModeActive = false
        }

        outputFrame(footerRender.frame, priority)
    }

    let attachmentStore = AttachmentStore()

    _ = agent.subscribe { @MainActor event, _ in
        await MainActor.run {
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

            if case .contextCompacted(let before, let after) = event {
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

    let controller = PromptController(agent: agent, modelStore: modelStore, attachmentStore: attachmentStore, sessionStore: sessionStore)

    let keyEvents: AsyncStream<KeyEvent>
    let inputReader: InputReader?
    if isInteractiveTTY {
        let (stream, continuation) = AsyncStream.makeStream(of: KeyEvent.self)
        let reader = InputReader { events in
            for event in events {
                continuation.yield(event)
            }
        }
        do {
            try reader.start()
            inputReader = reader
            keyEvents = stream
        } catch {
            continuation.finish()
            inputReader = nil
            keyEvents = AsyncStream { $0.finish() }
        }
    } else {
        inputReader = nil
        keyEvents = AsyncStream { $0.finish() }
    }
    defer { inputReader?.stop() }

    // 后台 queue 监视
    let bgMonitor = Task { @MainActor in
        while !Task.isCancelled {
            await refreshQueueLines()
            renderFrame()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func handleSubmitResult(_ result: PromptController.SubmitResult) -> Bool {
        switch result {
        case .submitted:
            isAbortRequested = false
            activeFooterNotice = nil
            didCompactRecently = false
            return true
        case .feedback(let text):
            activeFooterNotice = FooterNotice(text: text, priority: .command)
            didCompactRecently = false
            renderFrame(priority: .immediate)
            return true
        case .showModelPicker(let state):
            activeModelPicker = state
            renderFrame(priority: .immediate)
            return true
        case .exit:
            saveLastSession()
            bgMonitor.cancel()
            if let renderLoop { renderLoop.stop() }
            return false
        }
    }

    func handleResolvedKey(_ resolved: ResolvedKey<KeyAction>) async -> Bool {
        switch resolved {
        case .action(let keyAction):
            if var modelPicker = activeModelPicker {
                switch keyAction {
                case .historyPrev, .moveUp:
                    _ = modelPicker.handle(.moveUp)
                    activeModelPicker = modelPicker
                    renderFrame(priority: .immediate)
                    return true
                case .historyNext, .moveDown:
                    _ = modelPicker.handle(.moveDown)
                    activeModelPicker = modelPicker
                    renderFrame(priority: .immediate)
                    return true
                case .submit, .insertNewline:
                    let outcome = modelPicker.handle(.confirm)
                    activeModelPicker = nil
                    if case .confirmed(let item) = outcome {
                        do {
                            let result = try await controller.submit("/model \(item.id)")
                            return handleSubmitResult(result)
                        } catch {
                            renderer.applyCore(.notification(text: "[error] \(error)"))
                            renderFrame(priority: .immediate)
                            return true
                        }
                    } else {
                        renderFrame(priority: .immediate)
                        return true
                    }
                case .cancel:
                    _ = modelPicker.handle(.cancel)
                    activeModelPicker = nil
                    renderFrame(priority: .immediate)
                    return true
                case .exit:
                    saveLastSession()
                    bgMonitor.cancel()
                    if let renderLoop { renderLoop.stop() }
                    return false
                default:
                    return true
                }
            }

            switch keyAction {
            case .insert(let c):
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.insert(c))
                renderFrame(priority: .immediate)
                return true

            case .delete:
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.backspace)
                renderFrame(priority: .immediate)
                return true

            case .deleteForward:
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.deleteForward)
                renderFrame(priority: .immediate)
                return true

            case .submit, .insertNewline:
                if keyAction == .insertNewline && !agent.state.isStreaming {
                    inputState.handle(.insertNewline)
                    renderFrame(priority: .immediate)
                    return true
                }

                let submittedText = inputState.text
                let trimmed = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasAttachments = !attachmentStore.isEmpty
                inputHistory.commit(submittedText)
                inputState.handle(.clear)
                renderFrame(priority: .immediate)

                if !trimmed.isEmpty || hasAttachments {
                    do {
                        let result = try await controller.submit(trimmed)
                        return handleSubmitResult(result)
                    } catch {
                        activeFooterNotice = FooterNotice(text: "[error] \(error)", priority: .error)
                        renderFrame(priority: .immediate)
                        return true
                    }
                }
                return true

            case .cancel:
                let hasRunningBackgroundTasks: Bool
                if let bgManager = agent.backgroundTaskManager {
                    let tasks = await bgManager.status()
                    hasRunningBackgroundTasks = tasks.contains { $0.status == .running }
                } else {
                    hasRunningBackgroundTasks = false
                }

                let intent = resolveEscapeIntent(
                    isStreaming: agent.state.isStreaming,
                    hasRunningBackgroundTasks: hasRunningBackgroundTasks
                )

                switch intent {
                case .abortStreaming:
                    isAbortRequested = true
                    activeFooterNotice = nil
                    didCompactRecently = false
                    agent.abort()
                    if let blockID = currentAssistantBlockID {
                        renderer.applyCore(.blockCancel(id: blockID))
                        currentAssistantBlockID = nil
                    }
                    inputState.handle(.clear)
                    inputHistory.reset()
                    renderFrame(priority: .immediate)

                case .killBackgroundTasks:
                    isAbortRequested = false
                    didCompactRecently = false
                    if let bgManager = agent.backgroundTaskManager {
                        let cancelledCount = await bgManager.cancelAll(by: "user")
                        if cancelledCount > 0 {
                            activeFooterNotice = FooterNotice(
                                text: "cancelled \(cancelledCount) background task\(cancelledCount == 1 ? "" : "s")",
                                priority: .command
                            )
                        }
                        await refreshQueueLines()
                    }
                    inputState.handle(.clear)
                    inputHistory.reset()
                    renderFrame(priority: .immediate)

                case .clearInput:
                    isAbortRequested = false
                    activeFooterNotice = nil
                    didCompactRecently = false
                    inputState.handle(.clear)
                    inputHistory.reset()
                    renderFrame(priority: .immediate)
                }
                return true

            case .exit:
                saveLastSession()
                bgMonitor.cancel()
                if let renderLoop { renderLoop.stop() }
                return false

            case .historyPrev:
                activeFooterNotice = nil
                didCompactRecently = false
                if let text = inputHistory.prev() {
                    inputState.handle(.replace(text))
                    renderFrame(priority: .immediate)
                }
                return true

            case .historyNext:
                activeFooterNotice = nil
                didCompactRecently = false
                if let text = inputHistory.next() {
                    inputState.handle(.replace(text))
                    renderFrame(priority: .immediate)
                } else if inputHistory.isAtCurrent {
                    inputState.handle(.clear)
                    renderFrame(priority: .immediate)
                }
                return true

            case .moveLeft:
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.moveLeft)
                renderFrame(priority: .immediate)
                return true

            case .moveRight:
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.moveRight)
                renderFrame(priority: .immediate)
                return true

            case .moveUp:
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.moveUp)
                renderFrame(priority: .immediate)
                return true

            case .moveDown:
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.moveDown)
                renderFrame(priority: .immediate)
                return true

            case .moveToLineStart:
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.moveToLineStart)
                renderFrame(priority: .immediate)
                return true

            case .moveToLineEnd:
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.moveToLineEnd)
                renderFrame(priority: .immediate)
                return true

            case .moveToBufferStart:
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.moveToBufferStart)
                renderFrame(priority: .immediate)
                return true

            case .moveToBufferEnd:
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.moveToBufferEnd)
                renderFrame(priority: .immediate)
                return true

            case .killToLineStart:
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.killToLineStart)
                renderFrame(priority: .immediate)
                return true

            case .killToLineEnd:
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.killToLineEnd)
                renderFrame(priority: .immediate)
                return true

            case .paste(let text):
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.insertText(text))
                renderFrame(priority: .immediate)
                return true

            case .newTab, .closeTab:
                // Tab management is AppKit-only; TUI operates on a single session.
                return true

            case .ignore:
                return true
            }

        case .passthrough(let event):
            switch event.key {
            case .character(let c) where !event.modifiers.contains(.ctrl):
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.insert(c))
                renderFrame(priority: .immediate)
            case .paste(let text):
                activeFooterNotice = nil
                didCompactRecently = false
                inputState.handle(.insertText(text))
                renderFrame(priority: .immediate)
            default:
                break
            }
            return true
        }
    }

    // 首帧渲染
    renderFrame(priority: .immediate)

    eventLoop: for await event in keyEvents {
        for resolved in keyResolver.feed(event) {
            if !(await handleResolvedKey(resolved)) {
                break eventLoop
            }
        }
        for resolved in keyResolver.tick() {
            if !(await handleResolvedKey(resolved)) {
                break eventLoop
            }
        }
    }

    saveLastSession()
    bgMonitor.cancel()
    if let renderLoop { renderLoop.stop() }
}
