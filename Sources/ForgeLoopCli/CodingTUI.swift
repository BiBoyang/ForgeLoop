import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI

/// 根据模型生成显示标签（纯函数，可测试）
func labelForModel(_ model: Model) -> String {
    if model.id == "faux-coding-model" {
        return "faux-coding-model · local scaffold"
    }
    return "\(model.name) (\(model.id))"
}

func forgeLoopMarkdownRenderOptions() -> MarkdownRenderOptions {
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
    let backgroundTasks: BackgroundTaskSummary
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
    if snapshot.backgroundTasks.runningCount > 0 {
        badges.append("\(snapshot.backgroundTasks.runningCount) bg running")
    }
    if snapshot.backgroundTasks.failedCount > 0 {
        badges.append("\(snapshot.backgroundTasks.failedCount) bg failed")
    }
    if snapshot.backgroundTasks.cancelledCount > 0 {
        badges.append("\(snapshot.backgroundTasks.cancelledCount) bg cancelled")
    }
    if snapshot.queuedMessageCount > 0 {
        badges.append("\(snapshot.queuedMessageCount) queued")
    }

    if !badges.isEmpty {
        lines.append(Style.dimmed(badges.joined(separator: " • ")))
    }

    return lines
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

// MARK: - KeyAction

/// 输入层按键动作抽象，避免 CodingTUI 主循环直接膨胀 KeyEvent 分支。
enum KeyAction: Sendable, Equatable {
    case insert(Character)
    case delete
    case deleteForward
    case submit
    case cancel
    case exit
    case historyPrev
    case historyNext
    case moveLeft
    case moveRight
    case moveToStart
    case moveToEnd
    case paste(String)
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

extension KeyEvent {
    /// 默认按键到动作映射；可注入替换以支持自定义快捷键。
    func toAction() -> KeyAction {
        switch self {
        case .char(let c):
            return .insert(c)
        case .backspace:
            return .delete
        case .delete:
            return .deleteForward
        case .enter:
            return .submit
        case .escape:
            return .cancel
        case .ctrlC:
            return .exit
        case .up:
            return .historyPrev
        case .down:
            return .historyNext
        case .left:
            return .moveLeft
        case .right:
            return .moveRight
        case .home:
            return .moveToStart
        case .end:
            return .moveToEnd
        case .paste(let text):
            return .paste(text)
        default:
            return .ignore
        }
    }
}

// MARK: - InputHistory

/// 最小输入历史，支持上下键导航。
struct InputHistory {
    private var entries: [String] = []
    private var index: Int = -1  // -1 表示当前编辑态

    mutating func commit(_ text: String) {
        guard !text.isEmpty else { return }
        entries.insert(text, at: 0)
        index = -1
    }

    mutating func prev() -> String? {
        guard index < entries.count - 1 else { return nil }
        index += 1
        return entries[index]
    }

    mutating func next() -> String? {
        guard index >= 0 else { return nil }
        index -= 1
        return index >= 0 ? entries[index] : nil
    }

    mutating func reset() {
        index = -1
    }

    var isAtCurrent: Bool { index < 0 }
}

private struct FooterRenderState {
    let inputLines: [String]
    let frame: [String]
    let cursorOffset: Int?
}

@MainActor
func runCodingTUIInternal(
    model: Model,
    cwd: String
) async throws {
    let runner = TUIRunner()
    let renderer = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())
    let agent = await makeCodingAgent(CodingAgentConfig(model: model, cwd: cwd))
    let layoutRenderer = LayoutRenderer()
    let modelStore = ModelStore()
    let pickerRenderer = ListPickerRenderer()

    let disableRenderLoop = ProcessInfo.processInfo.environment["FORGELOOP_TUI_RENDER_LOOP"] == "0"
    let renderLoop: RenderLoop? = disableRenderLoop
        ? nil
        : RenderLoop(render: { [runner] frame in
            runner.tui.requestRender(lines: frame)
        })

    let outputFrame: @Sendable ([String], Int?, RenderLoop.Priority) -> Void = { [runner, renderLoop] frame, cursorOffset, priority in
        if let cursorOffset {
            runner.tui.requestRender(lines: frame, cursorOffset: cursorOffset)
        } else if let renderLoop {
            renderLoop.submit(frame: frame, priority: priority)
        } else {
            runner.tui.requestRender(lines: frame)
        }
    }
    var hasPrintedStaticHeader = false
    var appendModeActive = false
    var transcriptAppendState = StreamingTranscriptAppendState()

    var inputState = TextInputState()
    var inputHistory = InputHistory()
    var activeModelPicker: ListPickerState?
    var queueLines: [String] = []
    var backgroundTaskSummary = BackgroundTaskSummary()
    var isAbortRequested = false
    var footerNoticeLines: [String] = []
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
        config: LayoutConfig
    ) -> FooterRenderState {
        var footerLayout = Layout()
        footerLayout.queue = queueLines
        footerLayout.status = footerNoticeLines + statusLines

        if let activeModelPicker {
            let inputLines = pickerRenderer.render(state: activeModelPicker)
            footerLayout.input = inputLines
            let frame = layoutRenderer.render(layout: footerLayout, config: config)
            return FooterRenderState(inputLines: inputLines, frame: frame, cursorOffset: nil)
        }

        let inputRender = inputState.render(prefix: "❯ ", totalWidth: config.terminalWidth)
        let inputLines = [inputRender.line]
        footerLayout.input = inputLines
        let frame = layoutRenderer.render(layout: footerLayout, config: config)
        return FooterRenderState(inputLines: inputLines, frame: frame, cursorOffset: inputRender.cursorOffset)
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
                backgroundTasks: backgroundTaskSummary
            )
        )

        let size = getTerminalSize()
        if let last = lastTerminalSize, let current = size, last != current {
            runner.tui.updateTerminalSize(width: current.columns, height: current.rows)
        }
        lastTerminalSize = size

        let config = LayoutConfig(
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

        guard runner.tui.isTTY else {
            var fullLayout = Layout()
            fullLayout.header = headerLines
            fullLayout.transcript = renderer.transcriptLines
            fullLayout.pinnedTranscriptRange = renderer.preferredPinnedRange
            fullLayout.queue = queueLines
            fullLayout.status = footerNoticeLines + statusLines
            fullLayout.input = footerRender.inputLines
            let frame = layoutRenderer.render(layout: fullLayout, config: config)
            outputFrame(frame, nil, priority)
            return
        }

        if !hasPrintedStaticHeader {
            runner.tui.appendFrame(lines: headerLines)
            hasPrintedStaticHeader = true
        }

        if agent.state.isStreaming {
            if !appendModeActive {
                runner.tui.requestRender(lines: [])
                appendModeActive = true
            }

            let appendedTranscriptLines = transcriptAppendState.consume(
                transcript: renderer.transcriptLines,
                activeRange: renderer.activeStreamingRange
            )
            if !appendedTranscriptLines.isEmpty {
                runner.tui.appendFrame(lines: appendedTranscriptLines)
            }
            return
        }

        if appendModeActive {
            let remainingTranscriptLines = transcriptAppendState.consume(
                transcript: renderer.transcriptLines,
                activeRange: nil
            )
            if !remainingTranscriptLines.isEmpty {
                runner.tui.appendFrame(lines: remainingTranscriptLines)
            }
            runner.tui.resetRetainedFrame()
            appendModeActive = false
        }

        outputFrame(footerRender.frame, footerRender.cursorOffset, priority)
    }

    _ = agent.subscribe { event, _ in
        await MainActor.run {
            let eventPriority: RenderLoop.Priority = {
                switch event {
                case .messageEnd, .agentEnd:
                    return .immediate
                default:
                    return .normal
                }
            }()

            if let coreEvent = toCoreRenderEvent(event) {
                renderer.applyCore(coreEvent)
            }

            let currentModel = agent.state.model
            let modelLabel = labelForModel(currentModel)
            if !agent.state.isStreaming {
                isAbortRequested = false
            }
            let size = getTerminalSize()
            if let last = lastTerminalSize, let current = size, last != current {
                runner.tui.updateTerminalSize(width: current.columns, height: current.rows)
            }
            lastTerminalSize = size

            _ = LayoutConfig(
                terminalHeight: size?.rows ?? 24,
                terminalWidth: size?.columns ?? 80
            )
            let headerLines = [
                Style.header("✻ forgeloop replica"),
                Style.dimmed("  \(modelLabel)"),
                Style.dimmed("  \(cwd)"),
                "",
            ]
            let config = LayoutConfig(
                terminalHeight: size?.rows ?? 24,
                terminalWidth: size?.columns ?? 80
            )
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
                    backgroundTasks: backgroundTaskSummary
                )
            )
            let footerRender: FooterRenderState = {
                var footerLayout = Layout()
                footerLayout.queue = queueLines
                footerLayout.status = footerNoticeLines + statusLines

                if let activeModelPicker {
                    let inputLines = pickerRenderer.render(state: activeModelPicker)
                    footerLayout.input = inputLines
                    let frame = layoutRenderer.render(layout: footerLayout, config: config)
                    return FooterRenderState(inputLines: inputLines, frame: frame, cursorOffset: nil)
                }

                let inputRender = inputState.render(prefix: "❯ ", totalWidth: config.terminalWidth)
                let inputLines = [inputRender.line]
                footerLayout.input = inputLines
                let frame = layoutRenderer.render(layout: footerLayout, config: config)
                return FooterRenderState(
                    inputLines: inputLines,
                    frame: frame,
                    cursorOffset: inputRender.cursorOffset
                )
            }()

            guard runner.tui.isTTY else {
                var fullLayout = Layout()
                fullLayout.header = headerLines
                fullLayout.transcript = renderer.transcriptLines
                fullLayout.pinnedTranscriptRange = renderer.preferredPinnedRange
                fullLayout.queue = queueLines
                fullLayout.status = footerNoticeLines + statusLines
                fullLayout.input = footerRender.inputLines
                let frame = layoutRenderer.render(
                    layout: fullLayout,
                    config: config
                )
                outputFrame(frame, nil, eventPriority)
                return
            }

            if !hasPrintedStaticHeader {
                runner.tui.appendFrame(lines: headerLines)
                hasPrintedStaticHeader = true
            }

            if agent.state.isStreaming {
                if !appendModeActive {
                    runner.tui.requestRender(lines: [])
                    appendModeActive = true
                }

                let appendedTranscriptLines = transcriptAppendState.consume(
                    transcript: renderer.transcriptLines,
                    activeRange: renderer.activeStreamingRange
                )
                if !appendedTranscriptLines.isEmpty {
                    runner.tui.appendFrame(lines: appendedTranscriptLines)
                }
                return
            }

            if appendModeActive {
                let remainingTranscriptLines = transcriptAppendState.consume(
                    transcript: renderer.transcriptLines,
                    activeRange: nil
                )
                if !remainingTranscriptLines.isEmpty {
                    runner.tui.appendFrame(lines: remainingTranscriptLines)
                }
                runner.tui.resetRetainedFrame()
                appendModeActive = false
            }

            outputFrame(footerRender.frame, footerRender.cursorOffset, eventPriority)
        }
    }

    let keyEvents = await runner.run()
    let controller = PromptController(agent: agent, modelStore: modelStore)

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
            footerNoticeLines = []
            return true
        case .feedback(let text):
            footerNoticeLines = makeFooterNoticeLines(text)
            renderFrame(priority: .immediate)
            return true
        case .showModelPicker(let state):
            activeModelPicker = state
            renderFrame(priority: .immediate)
            return true
        case .exit:
            bgMonitor.cancel()
            if let renderLoop { renderLoop.stop() }
            return false
        }
    }

    // 首帧渲染
    renderFrame(priority: .immediate)

    for await event in keyEvents {
        let action = event.toAction()

        if var modelPicker = activeModelPicker {
            switch action {
            case .historyPrev:
                _ = modelPicker.handle(.moveUp)
                activeModelPicker = modelPicker
                renderFrame(priority: .immediate)
                continue
            case .historyNext:
                _ = modelPicker.handle(.moveDown)
                activeModelPicker = modelPicker
                renderFrame(priority: .immediate)
                continue
            case .submit:
                let outcome = modelPicker.handle(.confirm)
                activeModelPicker = nil
                if case .confirmed(let item) = outcome {
                    do {
                        let result = try await controller.submit("/model \(item.id)")
                        if !handleSubmitResult(result) {
                            return
                        }
                    } catch {
                        renderer.applyCore(.notification(text: "[error] \(error)"))
                        renderFrame(priority: .immediate)
                    }
                } else {
                    renderFrame(priority: .immediate)
                }
                continue
            case .cancel:
                _ = modelPicker.handle(.cancel)
                activeModelPicker = nil
                renderFrame(priority: .immediate)
                continue
            case .exit:
                bgMonitor.cancel()
                if let renderLoop { renderLoop.stop() }
                return
            default:
                continue
            }
        }

        switch action {
        case .insert(let c):
            footerNoticeLines = []
            inputState.handle(.insert(c))
            renderFrame(priority: .immediate)

        case .delete:
            footerNoticeLines = []
            inputState.handle(.backspace)
            renderFrame(priority: .immediate)

        case .deleteForward:
            footerNoticeLines = []
            inputState.handle(.deleteForward)
            renderFrame(priority: .immediate)

        case .submit:
            let submittedText = inputState.text
            let trimmed = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
            inputHistory.commit(submittedText)
            inputState.handle(.clear)
            renderFrame(priority: .immediate)

            if !trimmed.isEmpty {
                do {
                    let result = try await controller.submit(trimmed)
                    if !handleSubmitResult(result) {
                        return
                    }
                } catch {
                    footerNoticeLines = makeFooterNoticeLines("[error] \(error)")
                    renderFrame(priority: .immediate)
                }
            }

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
                footerNoticeLines = []
                agent.abort()
                inputState.handle(.clear)
                inputHistory.reset()
                renderFrame(priority: .immediate)

            case .killBackgroundTasks:
                isAbortRequested = false
                if let bgManager = agent.backgroundTaskManager {
                    let cancelledCount = await bgManager.cancelAll(by: "user")
                    if cancelledCount > 0 {
                        footerNoticeLines = makeFooterNoticeLines(
                            "cancelled \(cancelledCount) background task\(cancelledCount == 1 ? "" : "s")"
                        )
                    }
                    await refreshQueueLines()
                }
                inputState.handle(.clear)
                inputHistory.reset()
                renderFrame(priority: .immediate)

            case .clearInput:
                isAbortRequested = false
                footerNoticeLines = []
                inputState.handle(.clear)
                inputHistory.reset()
                renderFrame(priority: .immediate)
            }

        case .exit:
            bgMonitor.cancel()
            if let renderLoop { renderLoop.stop() }
            return

        case .historyPrev:
            footerNoticeLines = []
            if let text = inputHistory.prev() {
                inputState.handle(.replace(text))
                renderFrame(priority: .immediate)
            }

        case .historyNext:
            footerNoticeLines = []
            if let text = inputHistory.next() {
                inputState.handle(.replace(text))
                renderFrame(priority: .immediate)
            } else if inputHistory.isAtCurrent {
                inputState.handle(.clear)
                renderFrame(priority: .immediate)
            }

        case .moveLeft:
            footerNoticeLines = []
            inputState.handle(.moveLeft)
            renderFrame(priority: .immediate)

        case .moveRight:
            footerNoticeLines = []
            inputState.handle(.moveRight)
            renderFrame(priority: .immediate)

        case .moveToStart:
            footerNoticeLines = []
            inputState.handle(.moveToStart)
            renderFrame(priority: .immediate)

        case .moveToEnd:
            footerNoticeLines = []
            inputState.handle(.moveToEnd)
            renderFrame(priority: .immediate)

        case .paste(let text):
            footerNoticeLines = []
            inputState.handle(.insertText(text))
            renderFrame(priority: .immediate)

        case .ignore:
            break
        }
    }

    bgMonitor.cancel()
    if let renderLoop { renderLoop.stop() }
}
