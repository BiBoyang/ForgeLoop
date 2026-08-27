import AppKit
import Foundation
import ForgeLoopCli
import ForgeLoopTUI

// MARK: - Window Setup

extension AppController {
    func setupWindow() {
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

        let gitToggle = NSButton(title: "Git", target: self, action: #selector(gitPanelToggled(_:)))
        gitToggle.bezelStyle = .rounded
        gitToggle.toolTip = "Show/hide the git panel"

        let headerBar = NSStackView()
        headerBar.orientation = .horizontal
        headerBar.spacing = 12
        headerBar.addArrangedSubview(title)
        headerBar.addArrangedSubview(tabSelector)
        headerBar.addArrangedSubview(modelPicker)
        headerBar.addArrangedSubview(gitToggle)

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
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        // Chat on the left, git panel on the right. The panel keeps its width
        // when the window resizes; the chat area absorbs the difference.
        let panel = GitPanelController(workingDirectory: URL(fileURLWithPath: cwd))
        panel.onOpenSession = { [weak self] path in
            self?.createNewTab(workingDirectory: path)
        }
        let panelView = panel.view

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let contentWidth = initialFrame.width - 32
        let panelWidth: CGFloat = 300
        root.frame = NSRect(x: 0, y: 0, width: max(200, contentWidth - panelWidth), height: 100)
        panelView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: 100)
        splitView.addArrangedSubview(root)
        splitView.addArrangedSubview(panelView)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        guard let contentView = window.contentView else {
            fatalError("NSWindow contentView is missing")
        }

        contentView.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            inputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])

        // The collapsed state survives restarts; NSSplitView collapses a
        // subview by hiding it, divider included.
        panelView.isHidden = UserDefaults.standard.bool(forKey: "ForgeLoopGitPanelCollapsed")

        self.window = window
        self.titleLabel = title
        self.statusLabel = status
        self.bgTaskLabel = bgTasks
        self.transcriptView = transcript
        self.inputView = input
        self.keyHintLabel = hints
        self.modelPicker = modelPicker
        self.tabSelector = tabSelector
        self.gitPanel = panel
    }

    @objc func gitPanelToggled(_ sender: NSButton) {
        guard let panelView = gitPanel?.view else { return }
        panelView.isHidden.toggle()
        UserDefaults.standard.set(panelView.isHidden, forKey: "ForgeLoopGitPanelCollapsed")
    }

    func updateViewportWidth() {
        guard let inputView, !tabs.isEmpty else { return }
        let font = inputView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cellWidth = max(1, "W".size(withAttributes: [.font: font]).width)
        let contentWidth = inputView.enclosingScrollView?.contentSize.width ?? 600
        let estimatedColumns = max(1, Int(contentWidth / cellWidth) - 2)

        if activeTab.inputState.viewport?.width != estimatedColumns {
            activeTab.inputState.setViewport(Viewport(width: estimatedColumns))
        }
    }
}
