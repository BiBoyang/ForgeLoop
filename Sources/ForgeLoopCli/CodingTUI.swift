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

    let useRenderLoop = ProcessInfo.processInfo.environment["FORGELOOP_TUI_RENDER_LOOP"] == "1"
    let renderLoop: RenderLoop? = useRenderLoop
        ? RenderLoop(render: { [runner] frame in
            runner.tui.requestRender(lines: frame, cursorOffset: 0)
        })
        : nil

    let outputFrame: @Sendable ([String], RenderLoop.Priority) -> Void = { [runner, renderLoop] frame, priority in
        if let renderLoop {
            renderLoop.submit(frame: frame, priority: priority)
        } else {
            runner.tui.requestRender(lines: frame, cursorOffset: 0)
        }
    }

    var inputBuffer = ""
    var inputHistory = InputHistory()
    var queueLines: [String] = []
    var lastTerminalSize: TerminalSize? = getTerminalSize()

    func renderFrame(priority: RenderLoop.Priority = .normal) {
        let currentModel = agent.state.model
        let status = agent.state.isStreaming ? "streaming" : "idle"
        let toolCount = renderer.pendingToolCount
        let toolHint = toolCount > 0 ? " | \(toolCount) tool\(toolCount == 1 ? "" : "s") pending" : ""
        let statusBar = "model: \(labelForModel(currentModel)) | \(status)\(toolHint)"

        let size = getTerminalSize()
        if let last = lastTerminalSize, let current = size, last != current {
            runner.tui.updateTerminalSize(width: current.columns)
        }
        lastTerminalSize = size

        let config = LayoutConfig(
            terminalHeight: size?.rows ?? 24,
            terminalWidth: size?.columns ?? 80
        )
        var layout = Layout()
        layout.header = [
            Style.header("✻ forgeloop replica"),
            Style.dimmed("  \(labelForModel(currentModel))"),
            Style.dimmed("  \(cwd)"),
            "",
        ]
        layout.transcript = renderer.lines.all
        layout.queue = queueLines
        layout.status = [Style.dimmed(statusBar)]
        layout.input = ["❯ \(inputBuffer)"]

        let frame = layoutRenderer.render(layout: layout, config: config)
        outputFrame(frame, priority)
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
            let statusBar = "model: \(labelForModel(currentModel)) | \(status)\(toolHint)"

            let size = getTerminalSize()
            if let last = lastTerminalSize, let current = size, last != current {
                runner.tui.updateTerminalSize(width: current.columns)
            }
            lastTerminalSize = size

            let config = LayoutConfig(
                terminalHeight: size?.rows ?? 24,
                terminalWidth: size?.columns ?? 80
            )
            var layout = Layout()
            layout.header = [
                Style.header("✻ forgeloop replica"),
                Style.dimmed("  \(labelForModel(currentModel))"),
                Style.dimmed("  \(cwd)"),
                "",
            ]
            layout.transcript = renderer.lines.all
            layout.queue = queueLines
            layout.status = [Style.dimmed(statusBar)]
            layout.input = ["❯ \(inputBuffer)"]

            let frame = layoutRenderer.render(layout: layout, config: config)
            outputFrame(frame, eventPriority)
        }
    }

    let keyEvents = await runner.run()
    let controller = PromptController(agent: agent, modelStore: ModelStore())

    // 后台 queue 监视
    let bgMonitor = Task { @MainActor in
        while !Task.isCancelled {
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
            inputBuffer = ""
            inputHistory.reset()
            renderFrame(priority: .immediate)

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
