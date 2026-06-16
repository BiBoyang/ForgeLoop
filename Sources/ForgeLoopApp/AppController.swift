import AppKit
import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopCli
import ForgeLoopTUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let eventAdapter = AppKitEventAdapter()
    private let keyResolver = KeyResolver<KeyAction>(registry: makeKeybindings())
    private let sessionStore = SessionStore()
    private let modelStore = ModelStore()

    private var window: NSWindow?
    private var titleLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var transcriptView: NSTextView?
    private var inputView: NSTextView?
    private var keyHintLabel: NSTextField?
    private var keyMonitor: Any?

    private var modelPicker: NSPopUpButton?
    private var modelPickerIDs: [String] = []

    private let slashRegistry = makeDefaultSlashCommandRegistry()
    private var footerNotice: String? = nil
    private var bgTaskLines: [String] = []
    private var bgTaskLabel: NSTextField?

    private var inputState = MultiLineInputState(viewport: Viewport(width: 60))
    private var transcript: TranscriptRenderer!
    private var agent: Agent?
    private var currentBlockID: String?

    private var messageSegments: [MessageSegment] = []

    private let cwd = FileManager.default.currentDirectoryPath

    // MARK: - Message Segment Types

    enum MessageSegmentType {
        case user
        case assistant
        case toolHeader
        case toolResult(Bool)
        case thinking
        case error
        case notification
    }

    struct MessageSegment {
        let lines: [String]
        let type: MessageSegmentType
    }

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

                self.populateModelPicker()

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

                Task { @MainActor [weak self] in
                    while true {
                        try? await Task.sleep(for: .seconds(2))
                        guard let self, let manager = self.agent?.backgroundTaskManager else { continue }
                        let tasks = await manager.status()
                        self.bgTaskLines = tasks.map { record in
                            let symbol: String
                            switch record.status {
                            case .running: symbol = "◉"
                            case .success: symbol = "✓"
                            case .failed: symbol = "✗"
                            case .cancelled: symbol = "⊘"
                            }
                            let command = record.command.count > 40
                                ? String(record.command.prefix(40)) + "..."
                                : record.command
                            return "\(symbol) [\(record.id)] \(command)"
                        }
                        self.render()
                    }
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

        let modelPicker = NSPopUpButton()
        modelPicker.pullsDown = false
        modelPicker.target = self
        modelPicker.action = #selector(modelPickerChanged(_:))

        let headerBar = NSStackView()
        headerBar.orientation = .horizontal
        headerBar.spacing = 12
        headerBar.addArrangedSubview(title)
        headerBar.addArrangedSubview(modelPicker)

        let status = NSTextField(labelWithString: "● ready")
        status.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        status.usesSingleLineMode = false
        status.maximumNumberOfLines = 0
        status.lineBreakMode = .byWordWrapping

        let bgTasks = NSTextField(labelWithString: "")
        bgTasks.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        bgTasks.textColor = .secondaryLabelColor
        bgTasks.isEditable = false
        bgTasks.isSelectable = false
        bgTasks.usesSingleLineMode = false
        bgTasks.maximumNumberOfLines = 3
        bgTasks.lineBreakMode = .byWordWrapping
        bgTasks.setContentCompressionResistancePriority(.required, for: .vertical)

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

        root.addArrangedSubview(headerBar)
        root.addArrangedSubview(status)
        root.addArrangedSubview(bgTasks)
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
        self.bgTaskLabel = bgTasks
        self.transcriptView = transcript
        self.inputView = input
        self.keyHintLabel = hints
        self.modelPicker = modelPicker
    }

    // MARK: - Model Picker

    private func populateModelPicker() {
        guard let agent, let picker = modelPicker else { return }
        let items = suggestedModelPickerItems(for: agent.state.model)
        picker.removeAllItems()
        modelPickerIDs = items.map { $0.id }
        for item in items {
            picker.addItem(withTitle: item.title)
        }
        if let index = items.firstIndex(where: { $0.id == agent.state.model.id }) {
            picker.selectItem(at: index)
        }
    }

    @objc private func modelPickerChanged(_ sender: NSPopUpButton) {
        guard let agent else { return }
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < modelPickerIDs.count else { return }
        let modelID = modelPickerIDs[index]
        guard modelID != agent.state.model.id else { return }
        let newModel = switchedModel(from: agent.state.model, to: modelID)
        modelStore.save(newModel)
        agent.state.model = newModel
        populateModelPicker()
        render()
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
        footerNotice = nil

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
        footerNotice = nil

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
        footerNotice = nil
        guard let agent else { return }
        let text = inputState.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        inputState.handle(.clear)
        guard !trimmed.isEmpty else { return }

        if trimmed.hasPrefix("/") {
            let result = slashRegistry.execute(
                trimmed,
                context: SlashCommandContext(
                    agent: agent,
                    modelStore: modelStore,
                    attachmentStore: AttachmentStore(),
                    sessionStore: sessionStore
                )
            )
            switch result {
            case .feedback(let text):
                footerNotice = text
            case .submitted:
                footerNotice = nil
            case .exit:
                NSApp.terminate(nil)
            case .showModelPicker:
                footerNotice = "Model picker is not supported in the AppKit window."
            }
            render()
            return
        }

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

        // Status bar: phase | model | message count | pending tools | bg running.
        var parts: [String] = []
        parts.append(agent.state.isStreaming ? "● generating" : "● ready")
        parts.append("model: \(agent.state.model.id)")
        parts.append("\(agent.state.messages.count) messages")
        if let pending = transcript?.pendingToolCount, pending > 0 {
            parts.append("\(pending) tools pending")
        }
        let runningBg = bgTaskLines.filter { $0.hasPrefix("◉") }.count
        if runningBg > 0 {
            parts.append("\(runningBg) bg running")
        }
        var statusText = parts.joined(separator: "  |  ")
        if let footerNotice {
            statusText += "\n" + footerNotice
        }
        statusLabel?.stringValue = statusText

        // Background task display (max 3 lines).
        bgTaskLabel?.stringValue = bgTaskLines.prefix(3).joined(separator: "\n")

        // Colored transcript.
        messageSegments = buildMessageSegments(from: transcript?.transcriptLines ?? [])
        let attributedText = buildAttributedString(from: messageSegments)
        transcriptView?.textStorage?.setAttributedString(attributedText)
        scrollTranscriptToBottomIfNeeded()

        inputView?.string = inputState.lines.joined(separator: "\n")
        inputView?.scrollToEndOfDocument(nil)

        titleLabel?.stringValue = "ForgeLoop"
        modelPicker?.isEnabled = !agent.state.isStreaming
    }

    private func scrollTranscriptToBottomIfNeeded() {
        guard let scrollView = transcriptView?.enclosingScrollView,
              let documentView = scrollView.documentView else { return }
        let visibleRect = scrollView.documentVisibleRect
        let contentHeight = documentView.bounds.height
        let distanceToBottom = contentHeight - visibleRect.maxY
        if distanceToBottom < 30 {
            transcriptView?.scrollToEndOfDocument(nil)
        }
    }

    private func buildMessageSegments(from lines: [String]) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        for line in lines {
            let stripped = ansiStripped(line)
            let type: MessageSegmentType
            if stripped.hasPrefix("❯ ") {
                type = .user
            } else if stripped.hasPrefix("💭 ") {
                type = .thinking
            } else if stripped.hasPrefix("● ") || stripped.hasPrefix("⎿ running") {
                type = .toolHeader
            } else if stripped.hasPrefix("⎿ done") {
                type = .toolResult(true)
            } else if stripped.hasPrefix("⎿ failed") {
                type = .toolResult(false)
            } else if stripped.hasPrefix("▸ ") {
                type = .notification
            } else if stripped.hasPrefix("[error]") || stripped.hasPrefix("[cancelled]") {
                type = .error
            } else {
                type = .assistant
            }
            segments.append(MessageSegment(lines: [stripped], type: type))
        }
        return segments
    }

    private func buildAttributedString(from segments: [MessageSegment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = transcriptView?.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)

        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            let text = segment.lines.joined(separator: "\n")
            let color = colorForSegmentType(segment.type)
            let font: NSFont
            switch segment.type {
            case .thinking:
                font = italicFont
            default:
                font = baseFont
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: font,
            ]
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    private func colorForSegmentType(_ type: MessageSegmentType) -> NSColor {
        switch type {
        case .user:
            return .systemBlue
        case .assistant:
            return .labelColor
        case .toolHeader:
            return .systemOrange
        case .toolResult(let success):
            return success ? .systemGreen : .systemRed
        case .thinking:
            return .secondaryLabelColor
        case .error:
            return .systemRed
        case .notification:
            return .secondaryLabelColor
        }
    }

    private func ansiStripped(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "\u{001B}" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "[" {
                    var paramIndex = text.index(after: next)
                    while paramIndex < text.endIndex {
                        let paramChar = text[paramIndex]
                        if (0x40...0x7E).contains(paramChar.asciiValue ?? 0) {
                            index = text.index(after: paramIndex)
                            break
                        }
                        paramIndex = text.index(after: paramIndex)
                    }
                    if paramIndex >= text.endIndex {
                        break
                    }
                    continue
                }
            }
            result.append(char)
            index = text.index(after: index)
        }
        return result
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
