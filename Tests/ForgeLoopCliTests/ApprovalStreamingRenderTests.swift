import XCTest
@testable import ForgeLoopCli
import ForgeLoopTUI

/// TASK-approval-streaming-render：审批 picker 在流式期间的渲染计划与帧内容。
///
/// - `planStreamingApprovalRender` 是纯函数 seam，锁定 overlay 状态机真值表；
/// - 帧构建层验证 picker 内容确实进入 ComposedFrame 且为可交互 live 帧。
@MainActor
final class ApprovalStreamingRenderTests: XCTestCase {

    // MARK: - planStreamingApprovalRender 真值表

    func testPlanStreamingWithApprovalRendersFooter() {
        // 核心修复：streaming + 审批活跃 → 必须渲染含 picker 的 footer，不 early-return 丢弃
        let plan = planStreamingApprovalRender(isStreaming: true, approvalActive: true, overlayActive: false)
        XCTAssertTrue(plan.renderApprovalFooter)
        XCTAssertFalse(plan.eraseOverlay)
        XCTAssertFalse(plan.resetRetainedBeforeAppend, "overlay 未显示时无需复位 retained")
    }

    func testPlanStreamingOverlayVisibleNeedsResetBeforeAppend() {
        // picker live 帧 retained 时追加 transcript 前必须复位，否则新行写到 picker 下方
        let plan = planStreamingApprovalRender(isStreaming: true, approvalActive: true, overlayActive: true)
        XCTAssertTrue(plan.renderApprovalFooter)
        XCTAssertTrue(plan.resetRetainedBeforeAppend)
        XCTAssertFalse(plan.eraseOverlay)
    }

    func testPlanApprovalDismissedMidStreamErasesOverlay() {
        // 审批结束、仍在流式 → 擦除屏上 picker，随后 append 模式无缝继续
        let plan = planStreamingApprovalRender(isStreaming: true, approvalActive: false, overlayActive: true)
        XCTAssertTrue(plan.eraseOverlay)
        XCTAssertFalse(plan.renderApprovalFooter)
        XCTAssertFalse(plan.resetRetainedBeforeAppend)
    }

    func testPlanStreamEndsWithApprovalOpenErasesOverlay() {
        // 流式结束但审批仍打开 → 先擦除 overlay，由退出 append 模式的全帧重绘画回 picker
        let plan = planStreamingApprovalRender(isStreaming: false, approvalActive: true, overlayActive: true)
        XCTAssertTrue(plan.eraseOverlay)
        XCTAssertFalse(plan.renderApprovalFooter, "非流式渲染走既有 outputFrame 路径，不由 streaming 分支代劳")
        XCTAssertFalse(plan.resetRetainedBeforeAppend)
    }

    func testPlanNormalStreamingUntouched() {
        let plan = planStreamingApprovalRender(isStreaming: true, approvalActive: false, overlayActive: false)
        XCTAssertEqual(plan, StreamingApprovalRenderPlan(eraseOverlay: false, resetRetainedBeforeAppend: false, renderApprovalFooter: false))
    }

    func testPlanNonStreamingApprovalUntouched() {
        // 非 streaming 审批渲染行为不变：overlay 从未激活，plan 全否
        let plan = planStreamingApprovalRender(isStreaming: false, approvalActive: true, overlayActive: false)
        XCTAssertEqual(plan, StreamingApprovalRenderPlan(eraseOverlay: false, resetRetainedBeforeAppend: false, renderApprovalFooter: false))
    }

    func testPlanIdleUntouched() {
        let plan = planStreamingApprovalRender(isStreaming: false, approvalActive: false, overlayActive: false)
        XCTAssertEqual(plan, StreamingApprovalRenderPlan(eraseOverlay: false, resetRetainedBeforeAppend: false, renderApprovalFooter: false))
    }

    func testPlanDefensiveStaleOverlayErased() {
        // 防御分支：overlay 残留但既非流式也无审批 → 必须擦除
        let plan = planStreamingApprovalRender(isStreaming: false, approvalActive: false, overlayActive: true)
        XCTAssertTrue(plan.eraseOverlay)
        XCTAssertFalse(plan.renderApprovalFooter)
    }

    // MARK: - 帧构建层：picker 内容进入 ComposedFrame

    /// 复刻 makeFooterRenderState 的 approval 分支（queue/status 为空），
    /// 验证 streaming 期间要渲染的 footer 帧确实包含 picker 内容。
    private func buildApprovalFooterFrame(picker: ListPickerState) -> ComposedFrame {
        let pickerRenderer = ListPickerRenderer()
        let inputLines = pickerRenderer.render(state: picker)
        return CodingTUIFrameBuilder.build(input: .init(
            queueLines: [],
            statusLines: [],
            inputLines: inputLines,
            terminalHeight: 24,
            terminalWidth: 80,
            showHeader: false
        ))
    }

    func testApprovalFooterFrameContainsPickerContent() {
        let picker = CodingTUISession.makeApprovalPicker(
            command: "rm -rf /tmp/demo",
            reason: "operation not permitted"
        )
        let frame = buildApprovalFooterFrame(picker: picker)
        let allLines = frame.committed + frame.live

        XCTAssertTrue(allLines.contains { $0.contains("沙箱拒绝了这次命令") }, "帧必须包含 picker 标题")
        XCTAssertTrue(allLines.contains { $0.contains("允许一次") }, "帧必须包含允许选项")
        XCTAssertTrue(allLines.contains { $0.contains("拒绝") }, "帧必须包含拒绝选项")
        XCTAssertTrue(allLines.contains { $0.contains("rm -rf /tmp/demo") }, "帧必须包含命令预览")
    }

    func testApprovalFooterFrameIsInteractiveLiveFrame() {
        let picker = CodingTUISession.makeApprovalPicker(command: "ls", reason: "denied")
        let frame = buildApprovalFooterFrame(picker: picker)

        // picker 帧带 live 区 → 不会被 coalesce 成 committed-only，按键 diff 重绘有即时反馈
        XCTAssertFalse(frame.live.isEmpty, "picker 帧必须有 live 区以支持交互式 diff 重绘")
        XCTAssertFalse(
            shouldCoalesceWithRenderLoop(frame: frame, priority: .normal),
            "picker 帧不得被 coalesce（否则按键反馈要等 renderLoop 下一拍）"
        )
        XCTAssertNil(frame.cursorPlacement)
    }

    func testApprovalPickerDefaultsToDeny() {
        // 安全不变量：默认选中「拒绝」
        let picker = CodingTUISession.makeApprovalPicker(command: "ls", reason: "denied")
        XCTAssertEqual(picker.items[picker.selectedIndex].id, "deny")
    }

    func testApprovalPickerTruncatesLongCommand() {
        let longCommand = String(repeating: "x", count: 200)
        let picker = CodingTUISession.makeApprovalPicker(command: longCommand, reason: "denied")
        let subtitle = picker.subtitle ?? ""
        XCTAssertTrue(subtitle.contains("…"), "超过 100 字符的命令必须截断")
        XCTAssertFalse(subtitle.contains(longCommand))
    }
}
