import Foundation

/// 将布局组件渲染为终端帧（字符串数组）。
///
/// 渲染顺序：Header → Transcript → Queue → Status → Input。
/// Transcript 根据终端高度动态预算，保证 Queue、Status 和 Input 始终贴底可见。
/// 预算基于物理行数（考虑折行与 ANSI 可见宽度），但输出仍为逻辑行（由终端自然折行）。
public struct LayoutRenderer: Sendable {
    public init() {}

    public func render(layout: Layout, config: LayoutConfig) -> [String] {
        let w = config.terminalWidth
        var frame: [String] = []
        var usedPhysicalRows = 0

        // 1) Header
        if config.showHeader && !layout.header.isEmpty {
            frame.append(contentsOf: layout.header)
            usedPhysicalRows += layout.header.map { physicalRows(for: $0, width: w) }.reduce(0, +)
        }

        // 2) 预算：为 Queue + Status + Input 预留空间（按物理行数）
        let queuePhysical = layout.queue.isEmpty ? 0 : layout.queue.map { physicalRows(for: $0, width: w) }.reduce(0, +) + 1
        let statusPhysical = layout.status.isEmpty ? 0 : layout.status.map { physicalRows(for: $0, width: w) }.reduce(0, +) + 1
        let inputPhysical = layout.input.isEmpty ? 0 : layout.input.map { physicalRows(for: $0, width: w) }.reduce(0, +) + 1
        let overhead = queuePhysical + statusPhysical + inputPhysical

        let transcriptBudget = max(0, config.terminalHeight - usedPhysicalRows - overhead)

        // 从 transcript 末尾按物理行累积
        var visibleTranscript: [String] = []
        var transcriptPhysicalRows = 0
        for line in layout.transcript.reversed() {
            let rows = physicalRows(for: line, width: w)
            if transcriptPhysicalRows + rows > transcriptBudget {
                break
            }
            visibleTranscript.insert(line, at: 0)
            transcriptPhysicalRows += rows
        }
        frame.append(contentsOf: visibleTranscript)
        usedPhysicalRows += transcriptPhysicalRows

        // 3) Queue（divider + content）
        if !layout.queue.isEmpty {
            frame.append("")
            frame.append(contentsOf: layout.queue)
        }

        // 4) Status（divider + content）
        if !layout.status.isEmpty {
            frame.append("")
            frame.append(contentsOf: layout.status)
        }

        // 5) Input（divider + content）
        if !layout.input.isEmpty {
            frame.append("")
            frame.append(contentsOf: layout.input)
        }

        return frame
    }
}
