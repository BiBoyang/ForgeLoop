import AppKit
import Foundation

// MARK: - Message Segment Types

extension AppController {
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
}

// MARK: - Rendering

extension AppController {
    func render() {
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

        // Tab selector synchronization. A tab bound to a different working
        // directory (e.g. a git worktree) is labeled with the directory name.
        if let tabSelector {
            tabSelector.segmentCount = tabs.count
            for index in tabs.indices {
                let tab = tabs[index]
                if tab.agent.cwd == cwd {
                    tabSelector.setLabel("Session \(index + 1)", forSegment: index)
                } else {
                    let directory = URL(fileURLWithPath: tab.agent.cwd).lastPathComponent
                    tabSelector.setLabel(directory, forSegment: index)
                }
            }
            if tabSelector.selectedSegment != activeTabIndex {
                tabSelector.selectedSegment = activeTabIndex
            }
        }
    }

    func scrollTranscriptToBottomIfNeeded() {
        guard let scrollView = transcriptView?.enclosingScrollView,
              let documentView = scrollView.documentView else { return }
        let visibleRect = scrollView.documentVisibleRect
        let contentHeight = documentView.bounds.height
        let distanceToBottom = contentHeight - visibleRect.maxY
        if distanceToBottom < 30 {
            transcriptView?.scrollToEndOfDocument(nil)
        }
    }

    func buildMessageSegments(from lines: [String]) -> [MessageSegment] {
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

    func buildAttributedString(from segments: [MessageSegment]) -> NSAttributedString {
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
                    .font: font
                ]
                result.append(NSAttributedString(string: text, attributes: attributes))
            }
        }
        return result
    }

    func appendCodeBlock(
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
                .backgroundColor: backgroundColor
            ]
            result.append(NSAttributedString(string: line, attributes: attributes))
        }
    }

    func colorForSegmentType(_ type: MessageSegmentType) -> NSColor {
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

    func ansiStripped(_ text: String) -> String {
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
}
