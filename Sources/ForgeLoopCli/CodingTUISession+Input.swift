import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI

extension CodingTUISession {
    func handleSubmitResult(_ result: SubmitResult) -> Bool {
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
            bgMonitor?.cancel()
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
                    bgMonitor?.cancel()
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
                bgMonitor?.cancel()
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
}
