import AppKit
import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopCli
import ForgeLoopTUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let hybridAdapter = HybridRenderAdapter()
    private let eventAdapter = AppKitEventAdapter()
    private let keyResolver = KeyResolver<KeyAction>(registry: makeKeybindings())
    private let sessionStore = SessionStore()

    private var window: NSWindow?
    private var titleLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var transcriptView: NSTextView?
    private var inputView: NSTextView?
    private var keyHintLabel: NSTextField?
    private var keyMonitor: Any?

    private var inputState = MultiLineInputState(viewport: Viewport(width: 60))
    private var transcript: TranscriptRenderer!
    private var agent: Agent?
    private var currentBlockID: String?

    private let cwd = FileManager.default.currentDirectoryPath

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        installKeyMonitor()
        updateViewportWidth()

        Task {
            do {
                let resolved = try await resolveAgentAuth()
                let agent = await makeCodingAgent(CodingAgentConfig(model: resolved.model, cwd: cwd))
                self.agent = agent
                self.transcript = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())

                // Auto-restore last session if it exists.
                if let last = try? sessionStore.load(name: "last"), !last.messages.isEmpty {
                    agent.state.messages = last.messages
                    if last.modelID != agent.state.model.id {
                        agent.state.model = switchedModel(from: agent.state.model, to: last.modelID)
                    }
                }

                _ = agent.subscribe { @MainActor [weak self] event, _ in
                    guard let self else { return }
                    switch event {
                    case .messageStart(message: .assistant):
                        self.currentBlockID = UUID().uuidString
                    case .messageEnd(message: .assistant):
                        self.currentBlockID = nil
                    default:
                        break
                    }
                    let blockID = self.currentBlockID ?? "__assistant"
                    for coreEvent in toCoreRenderEvent(event, blockID: blockID) {
                        self.transcript.applyCore(coreEvent)
                    }
                    self.render()
                }

                self.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.render()
            } catch {
                await showErrorAndQuit(error)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeKeyMonitor()
    }

    func windowWillClose(_ notification: Notification) {
        let msgs = agent?.state.messages ?? []
        if !msgs.isEmpty {
            try? sessionStore.save(name: "last", modelID: agent?.state.model.id ?? "", messages: msgs)
        }
        NSApp.terminate(nil)
    }

    func windowDidResize(_ notification: Notification) {
        updateViewportWidth()
        render()
    }

    // MARK: - Setup

    private func setupWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ForgeLoop"
        window.delegate = self
        window.center()

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "ForgeLoop")
        title.font = NSFont.systemFont(ofSize: 24, weight: .semibold)

        let status = NSTextField(labelWithString: "● ready")
        status.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let transcript = NSTextView()
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.usesAdaptiveColorMappingForDarkAppearance = true
        transcript.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        transcript.textContainerInset = NSSize(width: 8, height: 8)

        let transcriptScroll = NSScrollView()
        transcriptScroll.borderType = .bezelBorder
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.documentView = transcript
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false

        let input = NSTextView()
        input.isEditable = false
        input.isSelectable = false
        input.drawsBackground = true
        input.backgroundColor = .controlBackgroundColor
        input.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        input.textContainerInset = NSSize(width: 8, height: 8)

        let inputScroll = NSScrollView()
        inputScroll.borderType = .bezelBorder
        inputScroll.hasVerticalScroller = true
        inputScroll.documentView = input
        inputScroll.translatesAutoresizingMaskIntoConstraints = false

        let hints = NSTextField(labelWithString: "Ctrl+J submit | Enter newline | Esc abort | Ctrl+C quit")
        hints.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hints.textColor = .secondaryLabelColor

        root.addArrangedSubview(title)
        root.addArrangedSubview(status)
        root.addArrangedSubview(transcriptScroll)
        root.addArrangedSubview(inputScroll)
        root.addArrangedSubview(hints)

        guard let contentView = window.contentView else {
            fatalError("NSWindow contentView is missing")
        }

        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            inputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])

        self.window = window
        self.titleLabel = title
        self.statusLabel = status
        self.transcriptView = transcript
        self.inputView = input
        self.keyHintLabel = hints
    }

    // MARK: - Input

    private func installKeyMonitor() {
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

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func handleResolvedKey(_ resolved: ResolvedKey<KeyAction>) async {
        switch resolved {
        case .action(let action):
            await handleKeyAction(action)
        case .passthrough(let event):
            handlePassthrough(event)
        }
    }

    private func handleKeyAction(_ action: KeyAction) async {
        guard let agent else {
            // Agent not ready yet; only allow exit.
            if action == .exit { NSApp.terminate(nil) }
            return
        }

        switch action {
        case .insert(let character):
            inputState.handle(.insert(character))

        case .insertNewline:
            if agent.state.isStreaming {
                submit()
            } else {
                inputState.handle(.insertNewline)
            }

        case .submit:
            submit()

        case .delete:
            inputState.handle(.backspace)

        case .deleteForward:
            inputState.handle(.deleteForward)

        case .moveLeft:
            inputState.handle(.moveLeft)

        case .moveRight:
            inputState.handle(.moveRight)

        case .moveUp:
            inputState.handle(.moveUp)

        case .moveDown:
            inputState.handle(.moveDown)

        case .moveToLineStart:
            inputState.handle(.moveToLineStart)

        case .moveToLineEnd:
            inputState.handle(.moveToLineEnd)

        case .moveToBufferStart:
            inputState.handle(.moveToBufferStart)

        case .moveToBufferEnd:
            inputState.handle(.moveToBufferEnd)

        case .killToLineStart:
            inputState.handle(.killToLineStart)

        case .killToLineEnd:
            inputState.handle(.killToLineEnd)

        case .paste(let text):
            inputState.handle(.insertText(text))

        case .cancel:
            if agent.state.isStreaming {
                abort()
            } else {
                inputState.handle(.clear)
            }

        case .exit:
            NSApp.terminate(nil)

        case .historyPrev, .historyNext, .ignore:
            break
        }
    }

    private func handlePassthrough(_ event: KeyEvent) {
        switch event.key {
        case .character(let character) where !event.modifiers.contains(.ctrl):
            inputState.handle(.insert(character))
        case .paste(let text):
            inputState.handle(.insertText(text))
        default:
            break
        }
    }

    // MARK: - Agent

    private func submit() {
        guard let agent else { return }
        let text = inputState.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        inputState.handle(.clear)
        guard !trimmed.isEmpty else { return }

        if agent.state.isStreaming {
            agent.steer(.user(UserMessage(text: trimmed)))
        } else {
            Task {
                try? await agent.prompt(trimmed)
            }
        }
    }

    private func abort() {
        guard let agent else { return }
        agent.abort()
        if let blockID = currentBlockID {
            transcript.applyCore(.blockCancel(id: blockID))
            currentBlockID = nil
        }
    }

    // MARK: - Rendering

    private func updateViewportWidth() {
        guard let inputView else { return }
        let font = inputView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cellWidth = max(1, "W".size(withAttributes: [.font: font]).width)
        let contentWidth = inputView.enclosingScrollView?.contentSize.width ?? 600
        let estimatedColumns = max(1, Int(contentWidth / cellWidth) - 2)

        if inputState.viewport?.width != estimatedColumns {
            inputState.setViewport(Viewport(width: estimatedColumns))
        }
    }

    private func render() {
        guard let agent else { return }
        let state = HybridRenderState(
            transcriptLines: transcript.transcriptLines,
            statusLines: [agent.state.isStreaming ? "● generating" : "● ready"],
            inputLines: inputState.lines,
            panelMeta: PanelMeta(
                title: "ForgeLoop",
                summary: "\(agent.state.messages.count) messages",
                statusBadge: agent.state.isStreaming ? "Streaming" : "Ready",
                isActive: agent.state.isStreaming
            )
        )
        let panel = hybridAdapter.appKitProjection(of: state)

        titleLabel?.stringValue = panel.meta.title
        statusLabel?.stringValue = panel.statusLines.joined(separator: " | ")
        transcriptView?.string = panel.transcriptLines.joined(separator: "\n")
        transcriptView?.scrollToEndOfDocument(nil)
        inputView?.string = panel.inputLines.joined(separator: "\n")
        inputView?.scrollToEndOfDocument(nil)

        if panel.inputFocused {
            keyHintLabel?.stringValue = "Ctrl+J submit | Enter newline | Esc abort | Ctrl+C quit"
        } else {
            keyHintLabel?.stringValue = "Ctrl+J submit | Enter newline | Esc abort | Ctrl+C quit"
        }
    }

    // MARK: - Errors

    private func showErrorAndQuit(_ error: Error) async {
        let alert = NSAlert()
        alert.messageText = "ForgeLoop failed to start"
        alert.informativeText = "\(error)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                alert.runModal()
                continuation.resume()
            }
        }
        NSApp.terminate(nil)
    }
}
