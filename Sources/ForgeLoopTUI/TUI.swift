import Foundation

public enum RenderStrategy: Sendable {
    case legacyAbsolute
    case inlineAnchor
}

public typealias FrameWriter = @Sendable (String) -> Void

public final class TUI: @unchecked Sendable {

    public let strategy: RenderStrategy
    public let isTTY: Bool
    public private(set) var terminalWidth: Int
    private let writer: FrameWriter

    private let lock = NSLock()
    private var previousLines: [String] = []
    private var lastFramePhysicalRows: Int = 0
    private var lastCursorAnchored: Bool = false

    public init(
        strategy: RenderStrategy? = nil,
        isTTY: Bool = true,
        terminalWidth: Int = 80,
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
        self.writer = writer ?? { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }

    /// Update terminal dimensions and force a full redraw on the next render.
    public func updateTerminalSize(width: Int) {
        lock.withLock {
            terminalWidth = width
        }
    }

    /// Force a full redraw on the next render (e.g. after SIGWINCH resize).
    public func invalidate() {
        // Inline path always does full region clear + redraw on non-empty prev,
        // so no state change is needed. Legacy path does full clear each frame.
    }

    public func requestRender(lines: [String], cursorOffset: Int? = nil) {
        if !isTTY {
            var output = lines.joined(separator: "\n")
            if !lines.isEmpty && cursorOffset == nil {
                output += "\n"
            }
            writer(output)
            return
        }

        switch strategy {
        case .legacyAbsolute:
            renderLegacy(lines: lines)
        case .inlineAnchor:
            renderInline(lines: lines, cursorOffset: cursorOffset)
        }
    }

    // MARK: - Legacy Absolute

    private func renderLegacy(lines: [String]) {
        // 锁内：仅状态快照
        let _ = lock.withLock {
            previousLines = lines
            lastFramePhysicalRows = totalPhysicalRows(for: lines)
            lastCursorAnchored = false
        }

        // 锁外：stdout I/O
        var output = "\u{1B}[2J\u{1B}[H"
        output += lines.joined(separator: "\n")
        if !lines.isEmpty {
            output += "\n"
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
            output += lines.joined(separator: "\n")
            if trailingNewline {
                output += "\n"
            }
        } else {
            // 增量：回锚 -> 清理旧帧区域 -> 重绘新帧
            // 回退行数取决于上一帧光标是否停在帧末行（anchored）
            let rewindRows = wasAnchored ? max(0, prevRows - 1) : prevRows

            // 1) 回到旧帧顶部
            output += "\r"
            if rewindRows > 0 {
                output += "\u{1B}[\(rewindRows)A"
            }

            // 2) 清理旧帧区域：逐行 ESC[2K + \r\n
            for _ in 0..<prevRows {
                output += "\u{1B}[2K\r\n"
            }

            // 3) 再次回到顶部（清理后光标在旧区域下方，固定回退 prevRows）
            if prevRows > 0 {
                output += "\u{1B}[\(prevRows)A"
            }

            // 4) 输出新帧
            output += lines.joined(separator: "\n")
            if trailingNewline {
                output += "\n"
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
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
