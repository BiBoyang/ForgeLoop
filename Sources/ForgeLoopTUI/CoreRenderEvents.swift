import Foundation

/// 通用渲染事件（去 chat 语义）。
///
/// 用于 `ForgeLoopTUI` Core 层，不绑定任何业务模型。
/// Chat 语义通过 Adapter 层注入。
public enum CoreRenderEvent: Sendable, Equatable {
    /// 插入静态文本行（不可更新）。
    case insert(lines: [String])

    /// 开始一个可更新的内容块。
    case blockStart(id: String)

    /// 更新内容块的行。
    case blockUpdate(id: String, lines: [String])

    /// 结束内容块，追加可选 footer（如错误消息）。
    case blockEnd(id: String, lines: [String], footer: String?)

    /// 开始一个追踪中的操作。
    /// - header: 操作标题行（如 "● toolName(args)"）
    /// - status: 初始状态行（如 "⎿ running..."）
    case operationStart(id: String, header: String, status: String)

    /// 结束操作，替换状态行为结果。
    /// - result: 可选结果文本（如 summary）
    case operationEnd(id: String, isError: Bool, result: String?)

    /// 通知消息（自动折叠）。
    case notification(text: String)
}
