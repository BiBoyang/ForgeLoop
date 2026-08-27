import AppKit
import Foundation
import ForgeLoopAgent
import ForgeLoopCli
import ForgeLoopTUI

// MARK: - Input

extension AppController {
    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            guard let keyEvent = self.eventAdapter.keyEvent(from: event) else { return event }
            Task { @MainActor in
                for resolved in self.keyResolver.feed(keyEvent) {
                    await self.handleResolvedKey(resolved)
                }
                self.updateViewportWidth()
                self.render()
            }
            return nil
        }
    }

    func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    func handleResolvedKey(_ resolved: ResolvedKey<KeyAction>) async {
        switch resolved {
        case .action(let action):
            await handleKeyAction(action)
        case .passthrough(let event):
            handlePassthrough(event)
        }
    }

    func handleKeyAction(_ action: KeyAction) async {
        guard !tabs.isEmpty else {
            if action == .exit { NSApp.terminate(nil) }
            return
        }

        activeTab.footerNotice = nil

        let agent = activeTab.agent

        switch action {
        case .insert(let character):
            activeTab.inputState.handle(.insert(character))

        case .insertNewline:
            if agent.state.isStreaming {
                await submit()
            } else {
                activeTab.inputState.handle(.insertNewline)
            }

        case .submit:
            await submit()

        case .delete:
            activeTab.inputState.handle(.backspace)

        case .deleteForward:
            activeTab.inputState.handle(.deleteForward)

        case .moveLeft:
            activeTab.inputState.handle(.moveLeft)

        case .moveRight:
            activeTab.inputState.handle(.moveRight)

        case .moveUp:
            activeTab.inputState.handle(.moveUp)

        case .moveDown:
            activeTab.inputState.handle(.moveDown)

        case .moveToLineStart:
            activeTab.inputState.handle(.moveToLineStart)

        case .moveToLineEnd:
            activeTab.inputState.handle(.moveToLineEnd)

        case .moveToBufferStart:
            activeTab.inputState.handle(.moveToBufferStart)

        case .moveToBufferEnd:
            activeTab.inputState.handle(.moveToBufferEnd)

        case .killToLineStart:
            activeTab.inputState.handle(.killToLineStart)

        case .killToLineEnd:
            activeTab.inputState.handle(.killToLineEnd)

        case .paste(let text):
            activeTab.inputState.handle(.insertText(text))

        case .cancel:
            if agent.state.isStreaming {
                abort()
            } else {
                activeTab.inputState.handle(.clear)
            }

        case .exit:
            NSApp.terminate(nil)

        case .historyPrev:
            if let text = activeTab.inputHistory.prev() {
                activeTab.inputState.handle(.replace(text))
            }

        case .historyNext:
            if let text = activeTab.inputHistory.next() {
                activeTab.inputState.handle(.replace(text))
            } else {
                activeTab.inputState.handle(.clear)
            }

        case .newTab:
            createNewTab()

        case .closeTab:
            closeCurrentTab()

        case .ignore:
            break
        }
    }

    func handlePassthrough(_ event: KeyEvent) {
        guard !tabs.isEmpty else { return }
        activeTab.footerNotice = nil

        switch event.key {
        case .character(let character) where !event.modifiers.contains(.ctrl):
            activeTab.inputState.handle(.insert(character))
        case .paste(let text):
            activeTab.inputState.handle(.insertText(text))
        default:
            break
        }
    }

    // MARK: Agent

    func submit() async {
        guard !tabs.isEmpty else { return }
        activeTab.footerNotice = nil
        let tab = activeTab
        let text = tab.inputState.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.inputState.handle(.clear)
        guard !trimmed.isEmpty else { return }
        tab.inputHistory.commit(trimmed)

        let result: SubmitResult
        do {
            result = try await tab.coordinator.submit(trimmed)
        } catch {
            tab.footerNotice = "[error] \(error)"
            render()
            return
        }
        switch result {
        case .feedback(let text):
            tab.footerNotice = text
        case .submitted:
            tab.footerNotice = nil
        case .exit:
            NSApp.terminate(nil)
        case .showModelPicker:
            tab.footerNotice = "Model picker is not supported in the AppKit window."
        }
        render()
    }

    func abort() {
        guard !tabs.isEmpty else { return }
        let agent = activeTab.agent
        agent.abort()
        if let blockID = activeTab.currentBlockID {
            activeTab.transcript.applyCore(.blockCancel(id: blockID))
            activeTab.currentBlockID = nil
        }
    }
}

// MARK: - NSTextViewDelegate

extension AppController {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSTextView.insertTab(_:)) {
            activeTab.inputState.handle(.insertText("    "))
            render()
            return true
        }
        return false
    }
}
