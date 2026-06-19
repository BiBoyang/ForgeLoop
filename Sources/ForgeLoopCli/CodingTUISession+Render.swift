import Foundation
import ForgeLoopAgent
import ForgeLoopTUI

struct FooterRenderState {
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

extension CodingTUISession {
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
            Style.dimmed("  \(agent.cwd)"),
            ""
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
            outputFrame(frame, priority: priority)
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

        outputFrame(footerRender.frame, priority: priority)
    }
}
