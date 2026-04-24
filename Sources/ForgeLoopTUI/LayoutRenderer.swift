import Foundation

/// 将布局组件渲染为终端帧（字符串数组）。
///
/// 渲染顺序：Header → Transcript → Queue → Status → Input。
/// Transcript 输出完整内容，由终端自己处理折行与滚动。
/// 输出仍为逻辑行（由终端自然折行）。
public struct LayoutRenderer: Sendable {
    public init() {}

    public func render(layout: Layout, config: LayoutConfig) -> [String] {
        var frame: [String] = []

        // 1) Header
        if config.showHeader && !layout.header.isEmpty {
            frame.append(contentsOf: layout.header)
        }

        // 2) Transcript — 完整输出，让终端自己处理显示与滚动
        frame.append(contentsOf: layout.transcript)

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
