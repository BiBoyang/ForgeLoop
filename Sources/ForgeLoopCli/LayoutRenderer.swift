import Foundation

/// 将布局组件渲染为终端帧（字符串数组）。
///
/// 渲染顺序：Header → Transcript → Queue → Status → Input。
/// Transcript 输出完整内容，由终端自己处理折行与滚动。
/// 输出仍为逻辑行（由终端自然折行）。
struct LayoutRenderer: Sendable {
    func render(layout: Layout, config: LayoutConfig) -> [String] {
        var frame: [String] = []

        if config.showHeader && !layout.header.isEmpty {
            frame.append(contentsOf: layout.header)
        }

        frame.append(contentsOf: layout.transcript)

        if !layout.queue.isEmpty {
            frame.append("")
            frame.append(contentsOf: layout.queue)
        }

        if !layout.status.isEmpty {
            frame.append("")
            frame.append(contentsOf: layout.status)
        }

        if !layout.input.isEmpty {
            frame.append("")
            frame.append(contentsOf: layout.input)
        }

        return frame
    }
}
