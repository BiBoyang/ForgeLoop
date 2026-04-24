import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum RenderStrategy: Sendable {
    case legacyAbsolute
    case inlineAnchor
}

public typealias FrameWriter = @Sendable (String) -> Void

private func writeToStandardOutput(_ text: String) {
    let data = Data(text.utf8)
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var written = 0

        while written < rawBuffer.count {
            let pointer = baseAddress.advanced(by: written)
            let remaining = rawBuffer.count - written
            let result = Darwin.write(STDOUT_FILENO, pointer, remaining)

            if result > 0 {
                written += result
                continue
            }

            if result == -1 && errno == EINTR {
                continue
            }

            if result == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                usleep(1_000)
                continue
            }

            break
        }
    }
}

public final class TUI: @unchecked Sendable {

    public let strategy: RenderStrategy
    public let isTTY: Bool
    public private(set) var terminalWidth: Int
    public private(set) var terminalHeight: Int
    private let writer: FrameWriter

    private let lock = NSLock()
    private var previousLines: [String] = []
    private var lastFramePhysicalRows: Int = 0
    private var lastCursorAnchored: Bool = false
    private let ttyNewline = "\r\n"

    public init(
        strategy: RenderStrategy? = nil,
        isTTY: Bool = true,
        terminalWidth: Int = 80,
        terminalHeight: Int = 24,
        writer: FrameWriter? = nil
    ) {
        let resolvedStrategy: RenderStrategy
        if let s = strategy {
            resolvedStrategy = s
        } else if
            let env = ProcessInfo.processInfo.environment["FORGELOOP_TUI_STRATEGY"],
            env.lowercased() == "legacy"
        {
            resolvedStrategy = .legacyAbsolute
        } else {
            resolvedStrategy = .inlineAnchor
        }

        self.strategy = resolvedStrategy
        self.isTTY = isTTY
        self.terminalWidth = terminalWidth
        self.terminalHeight = terminalHeight
        self.writer = writer ?? writeToStandardOutput
    }

    /// Update terminal dimensions and force a full redraw on the next render.
    public func updateTerminalSize(width: Int, height: Int? = nil) {
        lock.withLock {
            terminalWidth = width
            if let height {
                terminalHeight = height
            }
        }
    }

    /// Force a full redraw on the next render (e.g. after SIGWINCH resize).
    public func invalidate() {
        // Inline path always does full region clear + redraw on non-empty prev,
        // so no state change is needed. Legacy path does full clear each frame.
    }

    public func requestRender(lines: [String], cursorOffset: Int? = nil) {
        let normalizedLines = splitLogicalLines(lines)

        if !isTTY {
            var output = normalizedLines.joined(separator: "\n")
            if !normalizedLines.isEmpty && cursorOffset == nil {
                output += "\n"
            }
            writer(output)
            return
        }

        switch strategy {
        case .legacyAbsolute:
            renderLegacy(lines: normalizedLines, cursorOffset: cursorOffset)
        case .inlineAnchor:
            if shouldFallbackToFullRedraw(for: normalizedLines) {
                renderLegacy(lines: normalizedLines, cursorOffset: cursorOffset)
            } else {
                renderInline(lines: normalizedLines, cursorOffset: cursorOffset)
            }
        }
    }

    /// Append a full frame directly to terminal output without any retained-mode redraw.
    /// This preserves scrollback and lets the terminal naturally handle overflow.
    public func appendFrame(lines: [String]) {
        let normalizedLines = splitLogicalLines(lines)
        let separator = isTTY ? ttyNewline : "\n"
        var output = normalizedLines.joined(separator: separator)
        if !normalizedLines.isEmpty {
            output += separator
        }
        writer(output)
    }

    /// Drop retained redraw state so the next inline render starts fresh at the current cursor.
    public func resetRetainedFrame() {
        lock.withLock {
            previousLines = []
            lastFramePhysicalRows = 0
            lastCursorAnchored = false
        }
    }

    // MARK: - Legacy Absolute

    private func renderLegacy(lines: [String], cursorOffset: Int?) {
        // 锁内：仅状态快照
        let _ = lock.withLock {
            previousLines = lines
            lastFramePhysicalRows = totalPhysicalRows(for: lines)
            lastCursorAnchored = cursorOffset != nil
        }

        // 锁外：stdout I/O
        let anchored = cursorOffset != nil
        var output = "\u{1B}[2J\u{1B}[H"
        output += lines.joined(separator: ttyNewline)
        if !lines.isEmpty && !anchored {
            output += ttyNewline
        }
        if let offset = cursorOffset, offset > 0 {
            output += "\u{1B}[\(offset)D"
        }
        writer(output)
    }

    // MARK: - Inline Anchor

    private func renderInline(lines: [String], cursorOffset: Int?) {
        // 锁内：状态快照与更新
        let (prev, prevRows, wasAnchored) = lock.withLock {
            let oldPrev = previousLines
            let oldRows = lastFramePhysicalRows
            let anchored = lastCursorAnchored
            previousLines = lines
            lastFramePhysicalRows = totalPhysicalRows(for: lines)
            lastCursorAnchored = cursorOffset != nil
            return (oldPrev, oldRows, anchored)
        }

        // 锁外：构建 ANSI 序列并写入
        var output = ""

        let anchored = cursorOffset != nil
        let trailingNewline = !lines.isEmpty && !anchored

        if prev.isEmpty {
            // 首帧：直接在当前光标处输出，不清屏
            output += lines.joined(separator: ttyNewline)
            if trailingNewline {
                output += ttyNewline
            }
        } else {
            let firstDiff = firstDifferenceIndex(lhs: prev, rhs: lines)
            let anchorChanged = wasAnchored != anchored

            if firstDiff == nil, !anchorChanged {
                if let offset = cursorOffset, offset > 0 {
                    output += "\u{1B}[\(offset)D"
                    writer(output)
                }
                return
            }

            // 增量：仅重绘变化尾段（含 1 行上下文），避免全帧清理重绘。
            // 如果仅锚点模式变化（cursorOffset nil <-> non-nil），退化为全帧重绘以保持语义正确。
            let startLineIndex: Int
            if let diff = firstDiff {
                startLineIndex = diff > 0 ? (diff - 1) : 0
            } else {
                startLineIndex = 0
            }

            let prefixRows = totalPhysicalRows(for: prev.prefix(startLineIndex))
            let prevTailRows = totalPhysicalRows(for: prev.dropFirst(startLineIndex))
            let newTail = Array(lines.dropFirst(startLineIndex))

            // 回到变化区域顶部；上一帧 anchored 时，光标位于末行内，否则位于帧后下一行。
            let rewindRows = wasAnchored
                ? max(0, (prevRows - 1) - prefixRows)
                : max(0, prevRows - prefixRows)

            output += "\r"
            if rewindRows > 0 {
                output += "\u{1B}[\(rewindRows)A"
            }

            // 清理旧尾段
            for _ in 0..<prevTailRows {
                output += "\u{1B}[2K\r\n"
            }

            // 回到旧尾段顶部并重绘新尾段
            if prevTailRows > 0 {
                output += "\u{1B}[\(prevTailRows)A"
            }
            output += newTail.joined(separator: ttyNewline)
            if trailingNewline {
                output += ttyNewline
            }
        }

        // 5) Cursor marker: position cursor at input point using relative left-move
        if let offset = cursorOffset, offset > 0 {
            output += "\u{1B}[\(offset)D"
        }

        writer(output)
    }

    // MARK: - Physical Rows

    private func totalPhysicalRows(for lines: [String]) -> Int {
        lines.map { physicalRows(for: $0, width: terminalWidth) }.reduce(0, +)
    }

    private func totalPhysicalRows(for lines: ArraySlice<String>) -> Int {
        lines.reduce(into: 0) { partialResult, line in
            partialResult += physicalRows(for: line, width: terminalWidth)
        }
    }

    private func firstDifferenceIndex(lhs: [String], rhs: [String]) -> Int? {
        let minCount = min(lhs.count, rhs.count)
        for index in 0..<minCount where lhs[index] != rhs[index] {
            return index
        }
        return lhs.count == rhs.count ? nil : minCount
    }

    private func shouldFallbackToFullRedraw(for lines: [String]) -> Bool {
        lock.withLock {
            guard terminalHeight > 0 else { return false }
            let currentRows = totalPhysicalRows(for: lines)
            return max(lastFramePhysicalRows, currentRows) > terminalHeight
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
