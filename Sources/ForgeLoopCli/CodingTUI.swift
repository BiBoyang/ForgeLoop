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

// MARK: - KeyAction

/// 输入层按键动作抽象，避免 CodingTUI 主循环直接膨胀 KeyEvent 分支。
enum KeyAction: Sendable, Equatable {
    case insert(Character)
    case delete
    case submit
    case cancel
    case exit
    case historyPrev
    case historyNext
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

@MainActor
func runCodingTUIInternal(
    model: Model,
    cwd: String
) async throws {
    let runner = TUIRunner()
    let renderer = TranscriptRenderer()
    let agent = await makeCodingAgent(CodingAgentConfig(model: model, cwd: cwd))
    let layoutRenderer = LayoutRenderer()

    let disableRenderLoop = ProcessInfo.processInfo.environment["FORGELOOP_TUI_RENDER_LOOP"] == "0"
    let renderLoop: RenderLoop? = disableRenderLoop
        ? nil
        : RenderLoop(render: { [runner] frame in
            runner.tui.requestRender(lines: frame, cursorOffset: 0)
        })

    let outputFrame: @Sendable ([String], RenderLoop.Priority) -> Void = { [runner, renderLoop] frame, priority in
        if let renderLoop {
            renderLoop.submit(frame: frame, priority: priority)
        } else {
            runner.tui.requestRender(lines: frame, cursorOffset: 0)
        }
    }
    var hasPrintedStaticHeader = false
    var appendModeActive = false
    var transcriptAppendState = StreamingTranscriptAppendState()

    var inputBuffer = ""
    var inputHistory = InputHistory()
    var queueLines: [String] = []
    var lastTerminalSize: TerminalSize? = getTerminalSize()


    func refreshQueueLines() async {
        if let bgManager = agent.backgroundTaskManager {
            let tasks = await bgManager.status()
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
            queueLines = []
        }
    }

    func renderFrame(priority: RenderLoop.Priority = .normal) {
        let currentModel = agent.state.model
        let status = agent.state.isStreaming ? "streaming" : "idle"
        let toolCount = renderer.pendingToolCount
        let toolHint = toolCount > 0 ? " | \(toolCount) tool\(toolCount == 1 ? "" : "s") pending" : ""
        let statusBar = "model: \(labelForModel(currentModel)) | \(status)\(toolHint)"

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
            Style.dimmed("  \(labelForModel(currentModel))"),
            Style.dimmed("  \(cwd)"),
            "",
        ]
        var footerLayout = Layout()
        footerLayout.queue = queueLines
        footerLayout.status = [Style.dimmed(statusBar)]
        footerLayout.input = prefixedLogicalLines(prefix: "❯ ", text: inputBuffer)
        let footerFrame = layoutRenderer.render(layout: footerLayout, config: config)

        guard runner.tui.isTTY else {
            var fullLayout = Layout()
            fullLayout.header = headerLines
            fullLayout.transcript = renderer.lines.all
            fullLayout.pinnedTranscriptRange = renderer.preferredPinnedRange
            fullLayout.queue = queueLines
            fullLayout.status = [Style.dimmed(statusBar)]
            fullLayout.input = prefixedLogicalLines(prefix: "❯ ", text: inputBuffer)
            let frame = layoutRenderer.render(layout: fullLayout, config: config)
            outputFrame(frame, priority)
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
                transcript: renderer.lines.all,
                activeRange: renderer.activeStreamingRange
            )
            if !appendedTranscriptLines.isEmpty {
                runner.tui.appendFrame(lines: appendedTranscriptLines)
            }
            return
        }

        if appendModeActive {
            let remainingTranscriptLines = transcriptAppendState.consume(
                transcript: renderer.lines.all,
                activeRange: nil
            )
            if !remainingTranscriptLines.isEmpty {
                runner.tui.appendFrame(lines: remainingTranscriptLines)
            }
            runner.tui.resetRetainedFrame()
            appendModeActive = false
        }

        outputFrame(footerFrame, priority)
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
            let status = agent.state.isStreaming ? "streaming" : "idle"
            let toolCount = renderer.pendingToolCount
            let toolHint = toolCount > 0 ? " | \(toolCount) tool\(toolCount == 1 ? "" : "s") pending" : ""
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
                Style.dimmed("  \(labelForModel(currentModel))"),
                Style.dimmed("  \(cwd)"),
                "",
            ]
            let statusBar = "model: \(labelForModel(currentModel)) | \(status)\(toolHint)"
            var footerLayout = Layout()
            footerLayout.queue = queueLines
            footerLayout.status = [Style.dimmed(statusBar)]
            footerLayout.input = prefixedLogicalLines(prefix: "❯ ", text: inputBuffer)
            let footerFrame = layoutRenderer.render(
                layout: footerLayout,
                config: LayoutConfig(
                    terminalHeight: size?.rows ?? 24,
                    terminalWidth: size?.columns ?? 80
                )
            )

            guard runner.tui.isTTY else {
                var fullLayout = Layout()
                fullLayout.header = headerLines
                fullLayout.transcript = renderer.lines.all
                fullLayout.pinnedTranscriptRange = renderer.preferredPinnedRange
                fullLayout.queue = queueLines
                fullLayout.status = [Style.dimmed(statusBar)]
                fullLayout.input = prefixedLogicalLines(prefix: "❯ ", text: inputBuffer)
                let frame = layoutRenderer.render(
                    layout: fullLayout,
                    config: LayoutConfig(
                        terminalHeight: size?.rows ?? 24,
                        terminalWidth: size?.columns ?? 80
                    )
                )
                outputFrame(frame, eventPriority)
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
                    transcript: renderer.lines.all,
                    activeRange: renderer.activeStreamingRange
                )
                if !appendedTranscriptLines.isEmpty {
                    runner.tui.appendFrame(lines: appendedTranscriptLines)
                }
                return
            }

            if appendModeActive {
                let remainingTranscriptLines = transcriptAppendState.consume(
                    transcript: renderer.lines.all,
                    activeRange: nil
                )
                if !remainingTranscriptLines.isEmpty {
                    runner.tui.appendFrame(lines: remainingTranscriptLines)
                }
                runner.tui.resetRetainedFrame()
                appendModeActive = false
            }

            outputFrame(footerFrame, eventPriority)
        }
    }

    let keyEvents = await runner.run()
    let controller = PromptController(agent: agent, modelStore: ModelStore())

    // 后台 queue 监视
    let bgMonitor = Task { @MainActor in
        while !Task.isCancelled {
            await refreshQueueLines()
            renderFrame()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // 首帧渲染
    renderFrame(priority: .immediate)

    for await event in keyEvents {
        let action = event.toAction()
        switch action {
        case .insert(let c):
            inputBuffer.append(c)
            renderFrame(priority: .immediate)

        case .delete:
            if !inputBuffer.isEmpty {
                inputBuffer.removeLast()
                renderFrame(priority: .immediate)
            }

        case .submit:
            let trimmed = inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            inputHistory.commit(inputBuffer)
            inputBuffer = ""
            renderFrame(priority: .immediate)

            if !trimmed.isEmpty {
                do {
                    let result = try await controller.submit(trimmed)
                    switch result {
                    case .submitted:
                        break
                    case .feedback(let text):
                        print(text)
                    case .exit:
                        bgMonitor.cancel()
                        if let renderLoop { renderLoop.stop() }
                        return
                    }
                } catch {
                    print("[error] \(error)")
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
                agent.abort()
                inputBuffer = ""
                inputHistory.reset()
                renderFrame(priority: .immediate)

            case .killBackgroundTasks:
                if let bgManager = agent.backgroundTaskManager {
                    let cancelledCount = await bgManager.cancelAll(by: "user")
                    if cancelledCount > 0 {
                        renderer.applyCore(
                            .notification(
                                text: "cancelled \(cancelledCount) background task\(cancelledCount == 1 ? "" : "s")"
                            )
                        )
                    }
                    await refreshQueueLines()
                }
                inputBuffer = ""
                inputHistory.reset()
                renderFrame(priority: .immediate)

            case .clearInput:
                inputBuffer = ""
                inputHistory.reset()
                renderFrame(priority: .immediate)
            }

        case .exit:
            bgMonitor.cancel()
            if let renderLoop { renderLoop.stop() }
            return

        case .historyPrev:
            if let text = inputHistory.prev() {
                inputBuffer = text
                renderFrame(priority: .immediate)
            }

        case .historyNext:
            if let text = inputHistory.next() {
                inputBuffer = text
                renderFrame(priority: .immediate)
            } else if inputHistory.isAtCurrent {
                inputBuffer = ""
                renderFrame(priority: .immediate)
            }

        case .paste(let text):
            inputBuffer.append(text)
            renderFrame(priority: .immediate)

        case .ignore:
            break
        }
    }

    bgMonitor.cancel()
    if let renderLoop { renderLoop.stop() }
}
