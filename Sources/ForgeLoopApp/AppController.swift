import AppKit
import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopCli
import ForgeLoopTUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
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
    private var tabSelector: NSSegmentedControl?

    private let slashRegistry = makeDefaultSlashCommandRegistry()
    private var bgTaskLabel: NSTextField?

    private var tabs: [TabSession] = []
    private var activeTabIndex: Int = 0
    private var activeTab: TabSession {
        tabs[activeTabIndex]
    }

    private let cwd = FileManager.default.currentDirectoryPath

    // MARK: - Message Segment Types

    enum MessageSegmentType: Equatable {
        case user
        case assistant
        case toolHeader
        case toolResult(Bool)
        case thinking
        case error
        case notification
        case codeBlock
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

                // Restore tabs from tab-meta.json if present; otherwise create a single tab.
                await restoreTabs(resolved: resolved)

                if tabs.isEmpty {
                    let agent = await makeCodingAgent(CodingAgentConfig(model: resolved.model, cwd: cwd))
                    let coordinator = SessionCoordinator(
                        agent: agent,
                        modelStore: modelStore,
                        sessionStore: sessionStore
                    )
                    let transcript = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())
                    let tab = TabSession(id: UUID().uuidString, agent: agent, transcript: transcript, coordinator: coordinator)
                    tabs = [tab]
                    activeTabIndex = 0
                    setupSubscriptions(for: tab)
                }

                self.populateModelPicker()

                Task { @MainActor [weak self] in
                    while true {
                        try? await Task.sleep(for: .seconds(2))
                        guard let self, let manager = self.activeTab.agent.backgroundTaskManager else { continue }
                        let tasks = await manager.status()
                        self.activeTab.bgTaskLines = tasks.map { record in
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
        if let window {
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "ForgeLoopWindowFrame")
        }

        for tab in tabs {
            let msgs = tab.agent.state.messages
            if !msgs.isEmpty {
                try? sessionStore.save(name: "tab-\(tab.id)", modelID: tab.agent.state.model.id, messages: msgs)
            }
        }

        let tabIDs = tabs.map(\.id)
        let meta = TabMeta(tabIDs: tabIDs, activeIndex: activeTabIndex)
        if let metaData = try? JSONEncoder().encode(meta) {
            let metaURL = sessionStore.sessionsDirectory().appendingPathComponent("tab-meta.json")
            try? metaData.write(to: metaURL)
        }

        NSApp.terminate(nil)
    }

    func windowDidResize(_ notification: Notification) {
        updateViewportWidth()
        render()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSTextView.insertTab(_:)) {
            activeTab.inputState.handle(.insertText("    "))
            render()
            return true
        }
        return false
    }

    // MARK: - Tabs

    private func setupSubscriptions(for tab: TabSession) {
        _ = tab.agent.subscribe { @MainActor [weak self, weak tab] event, _ in
            guard let self, let tab else { return }
            switch event {
            case .messageStart(message: .assistant):
                tab.currentBlockID = UUID().uuidString
            case .messageEnd(message: .assistant):
                tab.currentBlockID = nil
            default:
                break
            }
            let blockID = tab.currentBlockID ?? "__assistant"
            for coreEvent in toCoreRenderEvent(event, blockID: blockID) {
                tab.transcript.applyCore(coreEvent)
            }
            self.render()
        }
    }

    private func restoreTabs(resolved: ResolvedAuth) async {
        let metaURL = sessionStore.sessionsDirectory().appendingPathComponent("tab-meta.json")
        guard FileManager.default.fileExists(atPath: metaURL.path),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(TabMeta.self, from: metaData) else {
            // No tab metadata yet. Try to migrate a previous "last" session into the first tab.
            if let last = try? sessionStore.load(name: "last"), !last.messages.isEmpty {
                let agent = await makeCodingAgent(CodingAgentConfig(model: resolved.model, cwd: cwd))
                let coordinator = SessionCoordinator(
                    agent: agent,
                    modelStore: modelStore,
                    sessionStore: sessionStore
                )
                try? await coordinator.restoreLastSession()
                let transcript = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())
                let tab = TabSession(id: UUID().uuidString, agent: agent, transcript: transcript, coordinator: coordinator)
                tabs = [tab]
                activeTabIndex = 0
                setupSubscriptions(for: tab)
            }
            return
        }

        for (index, id) in meta.tabIDs.enumerated() {
            guard let record = try? sessionStore.load(name: "tab-\(id)") else { continue }
            let agent = await makeCodingAgent(CodingAgentConfig(model: resolved.model, cwd: cwd))
            let coordinator = SessionCoordinator(
                agent: agent,
                modelStore: modelStore,
                sessionStore: sessionStore
            )
            try? await coordinator.agent.restoreSession(
                messages: record.messages,
                modelID: record.modelID
            )
            let transcript = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())
            let tab = TabSession(id: id, agent: agent, transcript: transcript, coordinator: coordinator)
            tabs.append(tab)
            setupSubscriptions(for: tab)
            if index == meta.activeIndex {
                activeTabIndex = tabs.count - 1
            }
        }

        if activeTabIndex >= tabs.count {
            activeTabIndex = max(0, tabs.count - 1)
        }
    }

    private func createNewTab() {
        guard let firstTab = tabs.first else { return }
        let config = CodingAgentConfig(model: firstTab.agent.state.model, cwd: cwd)
        Task {
            let agent = await makeCodingAgent(config)
            let coordinator = SessionCoordinator(
                agent: agent,
                modelStore: modelStore,
                sessionStore: sessionStore
            )
            let transcript = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())
            let tab = TabSession(id: UUID().uuidString, agent: agent, transcript: transcript, coordinator: coordinator)
            setupSubscriptions(for: tab)
            tabs.append(tab)
            activeTabIndex = tabs.count - 1
            render()
        }
    }

    private func closeCurrentTab() {
        guard !tabs.isEmpty else { NSApp.terminate(nil); return }
        let tab = tabs[activeTabIndex]
        let msgs = tab.agent.state.messages
        if !msgs.isEmpty {
            try? sessionStore.save(name: "tab-\(tab.id)", modelID: tab.agent.state.model.id, messages: msgs)
        }
        tabs.remove(at: activeTabIndex)
        if tabs.isEmpty {
            NSApp.terminate(nil)
            return
        }
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        }
        render()
    }

    @objc private func tabSelected(_ sender: NSSegmentedControl) {
        activeTabIndex = sender.selectedSegment
        render()
    }

    // MARK: - Setup

    private func setupWindow() {
        let defaultFrame = NSRect(x: 0, y: 0, width: 920, height: 640)
        let savedFrameString = UserDefaults.standard.string(forKey: "ForgeLoopWindowFrame")
        let restoredFrame = savedFrameString.map { NSRectFromString($0) }
        let initialFrame = restoredFrame.flatMap { $0.isEmpty ? nil : $0 } ?? defaultFrame
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ForgeLoop"
        window.delegate = self
        if restoredFrame?.isEmpty != false {
            window.center()
        }

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

        let tabSelector = NSSegmentedControl()
        tabSelector.segmentStyle = .capsule
        tabSelector.target = self
        tabSelector.action = #selector(tabSelected(_:))

        let headerBar = NSStackView()
        headerBar.orientation = .horizontal
        headerBar.spacing = 12
        headerBar.addArrangedSubview(title)
        headerBar.addArrangedSubview(tabSelector)
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
        input.delegate = self

        let inputScroll = NSScrollView()
        inputScroll.borderType = .bezelBorder
        inputScroll.hasVerticalScroller = true
        inputScroll.documentView = input
        inputScroll.translatesAutoresizingMaskIntoConstraints = false

        let hints = NSTextField(labelWithString: "Ctrl+J submit | Enter newline | Esc abort | Ctrl+C quit | ⌘T new tab | ⌘W close tab")
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
        self.tabSelector = tabSelector
    }

    // MARK: - Model Picker

    private func populateModelPicker() {
        guard !tabs.isEmpty, let picker = modelPicker else { return }
        let agent = activeTab.agent
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
        guard !tabs.isEmpty else { return }
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < modelPickerIDs.count else { return }
        let modelID = modelPickerIDs[index]
        guard modelID != activeTab.agent.state.model.id else { return }
        Task { @MainActor in
            try? await activeTab.coordinator.switchModel(to: modelID)
            populateModelPicker()
            render()
        }
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
        activeTab.footerNotice = nil

        guard !tabs.isEmpty else {
            if action == .exit { NSApp.terminate(nil) }
            return
        }

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

    private func handlePassthrough(_ event: KeyEvent) {
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

    // MARK: - Agent

    private func submit() async {
        activeTab.footerNotice = nil
        guard !tabs.isEmpty else { return }
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

    private func abort() {
        guard !tabs.isEmpty else { return }
        let agent = activeTab.agent
        agent.abort()
        if let blockID = activeTab.currentBlockID {
            activeTab.transcript.applyCore(.blockCancel(id: blockID))
            activeTab.currentBlockID = nil
        }
    }

    // MARK: - Rendering

    private func updateViewportWidth() {
        guard let inputView else { return }
        let font = inputView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cellWidth = max(1, "W".size(withAttributes: [.font: font]).width)
        let contentWidth = inputView.enclosingScrollView?.contentSize.width ?? 600
        let estimatedColumns = max(1, Int(contentWidth / cellWidth) - 2)

        if activeTab.inputState.viewport?.width != estimatedColumns {
            activeTab.inputState.setViewport(Viewport(width: estimatedColumns))
        }
    }

    private func render() {
        guard !tabs.isEmpty else { return }
        let agent = activeTab.agent

        // Status bar: phase | model | message count | pending tools | bg running.
        var parts: [String] = []
        parts.append(agent.state.isStreaming ? "● generating" : "● ready")
        parts.append("model: \(agent.state.model.id)")
        parts.append("\(agent.state.messages.count) messages")
        if activeTab.transcript.pendingToolCount > 0 {
            parts.append("\(activeTab.transcript.pendingToolCount) tools pending")
        }
        let runningBg = activeTab.bgTaskLines.filter { $0.hasPrefix("◉") }.count
        if runningBg > 0 {
            parts.append("\(runningBg) bg running")
        }
        var statusText = parts.joined(separator: "  |  ")
        if let footerNotice = activeTab.footerNotice {
            statusText += "\n" + footerNotice
        }
        statusLabel?.stringValue = statusText

        // Background task display (max 3 lines).
        bgTaskLabel?.stringValue = activeTab.bgTaskLines.prefix(3).joined(separator: "\n")

        // Colored transcript.
        activeTab.messageSegments = buildMessageSegments(from: activeTab.transcript.transcriptLines)
        let attributedText = buildAttributedString(from: activeTab.messageSegments)
        transcriptView?.textStorage?.setAttributedString(attributedText)
        scrollTranscriptToBottomIfNeeded()

        inputView?.string = activeTab.inputState.lines.joined(separator: "\n")
        inputView?.scrollToEndOfDocument(nil)

        titleLabel?.stringValue = "ForgeLoop"
        window?.title = "ForgeLoop — \(agent.state.model.id) · \(agent.state.messages.count) messages"
        modelPicker?.isEnabled = !agent.state.isStreaming

        // Tab selector synchronization.
        if let tabSelector {
            tabSelector.segmentCount = tabs.count
            for (i, _) in tabs.enumerated() {
                tabSelector.setLabel("Session \(i + 1)", forSegment: i)
            }
            if tabSelector.selectedSegment != activeTabIndex {
                tabSelector.selectedSegment = activeTabIndex
            }
        }
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
            if stripped.hasPrefix("│") {
                type = .codeBlock
            } else if stripped.hasPrefix("❯ ") {
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
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)

        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            let color = colorForSegmentType(segment.type)
            let font: NSFont
            switch segment.type {
            case .thinking:
                font = italicFont
            case .user, .error:
                font = boldFont
            default:
                font = baseFont
            }

            if segment.type == .codeBlock {
                appendCodeBlock(segment, to: result, baseFont: baseFont, defaultColor: color)
            } else {
                let text = segment.lines.joined(separator: "\n")
                let attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: color,
                    .font: font,
                ]
                result.append(NSAttributedString(string: text, attributes: attributes))
            }
        }
        return result
    }

    private func appendCodeBlock(
        _ segment: MessageSegment,
        to result: NSMutableAttributedString,
        baseFont: NSFont,
        defaultColor: NSColor
    ) {
        let backgroundColor = NSColor.controlBackgroundColor
        for (lineIndex, line) in segment.lines.enumerated() {
            if lineIndex > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            let lineColor = line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? NSColor.systemGreen : defaultColor
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: lineColor,
                .font: baseFont,
                .backgroundColor: backgroundColor,
            ]
            result.append(NSAttributedString(string: line, attributes: attributes))
        }
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
        case .codeBlock:
            return .labelColor
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

private struct TabMeta: Codable {
    var tabIDs: [String]
    var activeIndex: Int
}
