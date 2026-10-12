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

/// 流式期间审批 overlay 的渲染计划（纯函数 seam，单测锁定真值表）。
struct StreamingApprovalRenderPlan: Equatable {
    /// 先输出空帧 diff 清除屏上 picker live 帧（picker 已关闭或流式已结束时）。
    var eraseOverlay: Bool
    /// transcript 增量 append 前需复位 retained（picker live 帧 retained 时直接 append 会把新行写到 picker 下方）。
    var resetRetainedBeforeAppend: Bool
    /// 渲染含 picker 的 footer 帧（streaming + 审批活跃 → 不随 early-return 丢弃 footer）。
    var renderApprovalFooter: Bool
}

func planStreamingApprovalRender(
    isStreaming: Bool,
    approvalActive: Bool,
    overlayActive: Bool
) -> StreamingApprovalRenderPlan {
    // picker 已关闭或流式已结束：先擦除屏上 overlay，后续 append/全帧重绘才不会与残留 picker 错位。
    let eraseOverlay = overlayActive && (!approvalActive || !isStreaming)
    // 擦除后 overlay 视同不存在。
    let effectiveOverlay = overlayActive && !eraseOverlay
    return StreamingApprovalRenderPlan(
        eraseOverlay: eraseOverlay,
        resetRetainedBeforeAppend: isStreaming && approvalActive && effectiveOverlay,
        renderApprovalFooter: isStreaming && approvalActive
    )
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
        if let approvalPicker = activeApproval?.picker {
            let inputLines = pickerRenderer.render(state: approvalPicker)
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
                    isSelectingModel: activeModelPicker != nil || activeApproval != nil,
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

        // 审批 overlay 状态机：streaming 期间 picker 以 live 帧叠加渲染，
        // picker 关闭或流式结束时先擦除，保证 transcript append / 全帧重绘不与残留 picker 错位
        // （transcript 不丢行、picker 不重印）。
        let approvalPlan = planStreamingApprovalRender(
            isStreaming: agent.state.isStreaming,
            approvalActive: activeApproval != nil,
            overlayActive: approvalOverlayActive
        )
        if approvalPlan.eraseOverlay {
            tui.requestRender(lines: [])
            approvalOverlayActive = false
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

            if approvalPlan.renderApprovalFooter {
                // 流式期间的审批 picker 必须可见可交互：transcript 增量照常 append，
                // footer（picker 帧）照常渲染，不再随 streaming early-return 被丢弃。
                if !appendedTranscriptLines.isEmpty {
                    if approvalPlan.resetRetainedBeforeAppend {
                        // picker live 帧 retained 时直接 append 会把新行写到 picker 下方；
                        // 复位后由下面的 footer 渲染全量重绘 picker，保持上下顺序正确。
                        tui.resetRetainedFrame()
                    }
                    tui.appendFrame(lines: appendedTranscriptLines)
                }
                outputFrame(footerRender.frame, priority: priority)
                approvalOverlayActive = true
                return
            }

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
