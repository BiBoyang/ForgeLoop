import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI

/// 根据模型生成显示标签（纯函数，可测试）
func labelForModel(_ model: Model) -> String {
    if model.id == "faux-coding-model" {
        return "faux-coding-model · local scaffold"
    }
    return "\(model.name) (\(model.id))"
}

public func forgeLoopMarkdownRenderOptions() -> MarkdownRenderOptions {
    MarkdownRenderOptions(
        tablePolicy: TableRenderPolicy(
            maxRenderedWidth: 80,
            minColumnWidth: 4,
            maxColumnWidth: 28,
            truncationIndicator: "...",
            overflowBehavior: .compactThenTruncateThenDegrade
        )
    )
}

enum CodingStatusPhase: Sendable, Equatable {
    case ready
    case generating
    case aborting
    case selectingModel
    case runningBackgroundTasks
}

struct BackgroundTaskSummary: Sendable, Equatable {
    var runningCount: Int = 0
    var successCount: Int = 0
    var failedCount: Int = 0
    var cancelledCount: Int = 0
}

struct CodingStatusSnapshot: Sendable, Equatable {
    let modelLabel: String
    let phase: CodingStatusPhase
    let pendingToolCount: Int
    let queuedMessageCount: Int
    let attachmentCount: Int
    let backgroundTasks: BackgroundTaskSummary
    let didCompactRecently: Bool
}

func summarizeBackgroundTasks(_ tasks: [BackgroundTaskRecord]) -> BackgroundTaskSummary {
    var summary = BackgroundTaskSummary()
    for task in tasks {
        switch task.status {
        case .running:
            summary.runningCount += 1
        case .success:
            summary.successCount += 1
        case .failed:
            summary.failedCount += 1
        case .cancelled:
            summary.cancelledCount += 1
        }
    }
    return summary
}

func resolveStatusPhase(
    isStreaming: Bool,
    isAborting: Bool,
    isSelectingModel: Bool,
    hasRunningBackgroundTasks: Bool
) -> CodingStatusPhase {
    if isSelectingModel {
        return .selectingModel
    }
    if isAborting {
        return .aborting
    }
    if isStreaming {
        return .generating
    }
    if hasRunningBackgroundTasks {
        return .runningBackgroundTasks
    }
    return .ready
}

func makeStatusLines(snapshot: CodingStatusSnapshot) -> [String] {
    let phaseText: String
    switch snapshot.phase {
    case .ready:
        phaseText = Style.success("● ready")
    case .generating:
        phaseText = Style.running("● generating")
    case .aborting:
        phaseText = Style.warning("● aborting")
    case .selectingModel:
        phaseText = Style.running("● selecting model")
    case .runningBackgroundTasks:
        phaseText = Style.running("● background tasks")
    }

    var lines = ["\(phaseText) \(Style.dimmed("model: \(snapshot.modelLabel)"))"]

    var badges: [String] = []
    if snapshot.pendingToolCount > 0 {
        badges.append("\(snapshot.pendingToolCount) tool\(snapshot.pendingToolCount == 1 ? "" : "s") pending")
    }
    if snapshot.queuedMessageCount > 0 {
        badges.append("\(snapshot.queuedMessageCount) queued")
    }
    if snapshot.attachmentCount > 0 {
        badges.append("\(snapshot.attachmentCount) attachment\(snapshot.attachmentCount == 1 ? "" : "s")")
    }
    if snapshot.backgroundTasks.runningCount > 0 {
        badges.append("\(snapshot.backgroundTasks.runningCount) bg running")
    }
    if snapshot.backgroundTasks.failedCount > 0 {
        badges.append("\(snapshot.backgroundTasks.failedCount) bg failed")
    }
    if snapshot.backgroundTasks.cancelledCount > 0 {
        badges.append("\(snapshot.backgroundTasks.cancelledCount) bg cancelled")
    }
    if snapshot.didCompactRecently {
        badges.append("compacted")
    }

    if !badges.isEmpty {
        lines.append(Style.dimmed(badges.joined(separator: " • ")))
    }

    return lines
}

/// 生成输入区 lines。附件提示放在输入行上方；第一行加 prompt 前缀 "❯ "，
/// 后续行用 "  " 对齐，保证光标锚点落在输入区最后一行。
func makeInputLines(inputLines: [String], attachmentCount: Int) -> [String] {
    guard !inputLines.isEmpty else { return [] }
    let prompt = "❯ "
    let continuation = "  "
    var result: [String] = []
    if attachmentCount > 0 {
        result.append(Style.dimmed("  \(attachmentCount) attachment\(attachmentCount == 1 ? "" : "s")"))
    }
    for (idx, line) in inputLines.enumerated() {
        result.append(idx == 0 ? prompt + line : continuation + line)
    }
    return result
}

func makeFooterNoticeLines(_ text: String) -> [String] {
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else { return [] }

    return lines.enumerated().map { index, line in
        if index == 0 {
            return Style.warning("▸ \(line)")
        }
        return Style.dimmed(line)
    }
}

// MARK: - Footer Notice

/// Footer notice 的统一封装，用于管理 status bar 下方的临时反馈。
///
/// 职责边界（三者不可混淆）：
/// - Status bar（状态栏）= 持续状态：model、phase、badges（attachment count、queued count 等）。
///   始终可见，反映当前运行态，不由用户命令直接写入。
/// - Footer notice（底部通知）= 临时反馈：/compact、/attach、auto-compact 等一次性提示。
///   用户输入或新提交时自动清除。
/// - Transcript（对话区）= 真正对话内容：用户消息和 AI 回复。
///   slash 命令的反馈绝不塞入 transcript。
///
/// 替换规则：
/// - 新 notice 优先级 >= 旧 notice 时覆盖
/// - 当前无 notice 时直接接受
/// - 用户任何输入操作（打字、删除、移动光标等）清除所有 notice
/// - .submitted（提交成功）清除所有 notice
struct FooterNotice: Equatable {
    let lines: [String]
    let priority: Priority

    enum Priority: Int, Comparable {
        case info = 0      // auto-compact 等自动触发
        case command = 1   // slash 命令反馈 (/queue, /attachments, /compact 等)
        case error = 2     // 错误提示

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    init(text: String, priority: Priority) {
        self.lines = makeFooterNoticeLines(text)
        self.priority = priority
    }
}

/// 决定是否用新 notice 替换当前 notice。
/// 规则：新优先级 >= 旧优先级时替换；当前无 notice 时直接接受。
func resolveFooterNotice(current: FooterNotice?, incoming: FooterNotice) -> FooterNotice {
    guard let current = current else { return incoming }
    return incoming.priority >= current.priority ? incoming : current
}
