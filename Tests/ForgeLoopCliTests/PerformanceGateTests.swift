import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli
import ForgeLoopTUI

/// STEP-028B 性能门禁测试
///
/// 基于 028A 基线值定义阈值，关键指标回退超过阈值时 XCTFail。
///
/// 稳定化策略（D2 引入）：
/// 1. Warm-up 轮次：正式测量前先执行 10 轮，排除 JIT/缓存冷启动噪音。
/// 2. 多次采样取中位数：使用 p50 替代 avg，降低偶发尖峰误报。
/// 3. 相对阈值 + 绝对上限：thresholdFactor 控制相对回退，同时保留绝对上限
///    作为 sanity check。
/// 4. 失败输出包含观测值、阈值、偏差百分比、建议动作，便于快速判断是
///    回归还是环境噪音。
///
/// 基线更新规则（测试内注释，必须遵守）：
/// - 允许更新基线的情况：
///   1) 有明确性能优化/退化改动（PR 附 before/after 数据）
///   2) 测量模型变更（如迭代次数、采样策略、warm-up 轮次调整）
/// - 不允许更新基线的情况：
///   1) 仅因偶发抖动（同机 3 次运行中 2 次通过即可视为噪音）
///   2) CI 与本地环境差异（应通过环境 guard 或 thresholdFactor 调节，而非改基线）
/// - 更新基线前必须附带的数据：
///   1) 至少 3 次独立运行的 p50/median 值
///   2) 当前 thresholdFactor 下的通过/失败比例
///   3) 环境信息（OS 版本、CPU 型号、Swift 版本）
///
/// 基线来源：PerformanceBaselineTests 在本地 macOS arm64 环境的典型输出。
@MainActor
final class PerformanceGateTests: XCTestCase {

    // MARK: - 阈值配置

    /// 当前阈值系数。1.5 = 50% 回退告警，兼顾环境抖动与回归拦截。
    /// 待基线进一步稳定后可逐步收紧到 1.2 ~ 1.3。
    private let thresholdFactor: Double = 1.5

    /// Gate 采样迭代次数（比基线少，追求速度）。
    private let gateIterations = 100

    /// Warm-up 轮次（排除冷启动噪音）。
    private let warmUpIterations = 10

    // MARK: - 028A 基线常量（单位与阈值一致）

    /// render-small-first 基线（单位：微秒）。
    /// 2026-04-24 当前实现（安全 stdout + streaming transcript planner）实测约 40~42μs。
    /// D2 更新：基于 5 次 warm-up + p50 测量，典型值 48~52μs。
    private let baselineRenderSmallFirstMicros: Double = 55.0

    /// render-medium-first 基线（单位：微秒）。
    /// 2026-04-24 当前实现实测约 275~330μs。
    /// D2 更新：基于 warm-up + p50，典型值 350~380μs。
    private let baselineRenderMediumFirstMicros: Double = 400.0

    /// render-large-first 基线（单位：毫秒）。
    /// D2 更新：基于 warm-up + p50，典型值 1.8~2.0ms（远低于原 10ms 保守值）。
    private let baselineRenderLargeFirstMillis: Double = 5.0

    /// render-medium-rapid-refresh 基线（单位：微秒）。
    /// 典型值 430~450μs；diff 路径比首帧略慢（首帧 ~360μs）。
    private let baselineRenderMediumRapidRefreshMicros: Double = 600.0

    /// transcript-apply 基线（单位：微秒）。
    /// D2 更新：基于 warm-up + p50，典型值 15~18μs。
    private let baselineTranscriptApplyMicros: Double = 25.0

    /// steer-enqueue 基线（单位：微秒）。
    private let baselineSteerEnqueueMicros: Double = 500.0

    // MARK: - 测量辅助（稳定化版）

    private struct Timing {
        let medianNanos: UInt64
        let minNanos: UInt64
        let maxNanos: UInt64
        var medianMicros: Double { Double(medianNanos) / 1_000.0 }
        var medianMillis: Double { Double(medianNanos) / 1_000_000.0 }
    }

    /// 稳定化测量：先 warm-up，再采样，返回中位数（p50）。
    private func measureStable(iterations: Int, _ block: () -> Void) -> Timing {
        // Warm-up
        for _ in 0..<warmUpIterations {
            block()
        }
        // Formal sampling
        var times = [UInt64](repeating: 0, count: iterations)
        for i in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let end = DispatchTime.now().uptimeNanoseconds
            times[i] = end - start
        }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        return Timing(medianNanos: median, minNanos: sorted.first!, maxNanos: sorted.last!)
    }

    /// 格式化性能失败消息，包含观测值、阈值、偏差百分比、建议动作。
    /// F1 增强：失败信息必须直接回答——观测值、阈值、偏差百分比、推荐动作。
    private func gateFailureMessage(
        label: String,
        observed: Double,
        threshold: Double,
        unit: String
    ) -> String {
        let deviation = ((observed - threshold) / threshold) * 100.0
        let severity: String
        if deviation > 50 {
            severity = "SEVERE"
        } else if deviation > 20 {
            severity = "MODERATE"
        } else if deviation > 10 {
            severity = "MINOR"
        } else {
            severity = "MARGINAL"
        }
        var msg = "[\(severity)] \(label) exceeded gate"
        msg += " | observed=\(String(format: "%.2f", observed))\(unit)"
        msg += " | threshold=\(String(format: "%.2f", threshold))\(unit)"
        msg += " | deviation=\(String(format: "+%.1f", deviation))%"
        msg += " | action: re-run 3 times; if 2+/3 fail, check environment load or file regression issue."
        msg += " | docs: see docs/perf-regression-policy.md for severity table and baseline update rules."
        return msg
    }

    private func makeSmallFrame() -> [String] {
        [
            Style.header("✻ forgeloop replica"),
            Style.dimmed("  faux-coding-model · local scaffold"),
            Style.dimmed("  /Users/demo"),
            "",
            "Hello, world!",
            "",
            Style.dimmed("model: faux-coding-model · local scaffold | idle"),
        ]
    }

    private func makeMediumFrame() -> [String] {
        var lines: [String] = [
            Style.header("✻ forgeloop replica"),
            Style.dimmed("  faux-coding-model · local scaffold"),
            Style.dimmed("  /Users/demo"),
            "",
        ]
        for i in 0..<20 {
            lines.append("Line \(i): This is a sample transcript line for medium frame rendering.")
        }
        lines.append(contentsOf: ["", Style.dimmed("model: faux-coding-model · local scaffold | streaming | 2 tools pending")])
        return lines
    }

    private func makeLargeFrame() -> [String] {
        var lines: [String] = [
            Style.header("✻ forgeloop replica"),
            Style.dimmed("  faux-coding-model · local scaffold"),
            Style.dimmed("  /Users/demo"),
            "",
        ]
        for i in 0..<120 {
            lines.append("Line \(i): " + String(repeating: "x", count: 60))
        }
        lines.append(contentsOf: ["", Style.dimmed("model: faux-coding-model · local scaffold | streaming | 5 tools pending")])
        return lines
    }

    // MARK: - Gate 1) 渲染耗时

    func testGate_RenderSmallFirst() {
        let tui = TUI()
        let frame = makeSmallFrame()
        let timing = measureStable(iterations: gateIterations) {
            tui.requestRender(lines: frame)
        }
        let threshold = baselineRenderSmallFirstMicros * thresholdFactor
        XCTAssertLessThan(
            timing.medianMicros, threshold,
            gateFailureMessage(label: "render-small-first", observed: timing.medianMicros, threshold: threshold, unit: "μs")
        )
    }

    func testGate_RenderMediumFirst() {
        let tui = TUI()
        let frame = makeMediumFrame()
        let timing = measureStable(iterations: gateIterations) {
            tui.requestRender(lines: frame)
        }
        let threshold = baselineRenderMediumFirstMicros * thresholdFactor
        XCTAssertLessThan(
            timing.medianMicros, threshold,
            gateFailureMessage(label: "render-medium-first", observed: timing.medianMicros, threshold: threshold, unit: "μs")
        )
    }

    func testGate_RenderLargeFirst() {
        let tui = TUI()
        let frame = makeLargeFrame()
        let timing = measureStable(iterations: gateIterations) {
            tui.requestRender(lines: frame)
        }
        let threshold = baselineRenderLargeFirstMillis * thresholdFactor
        XCTAssertLessThan(
            timing.medianMillis, threshold,
            gateFailureMessage(label: "render-large-first", observed: timing.medianMillis, threshold: threshold, unit: "ms")
        )
    }

    func testGate_RenderMediumRapidRefresh() {
        let tui = TUI(terminalWidth: 200, terminalHeight: 100)
        var frame = makeMediumFrame()
        // Warm-up to establish retained state
        for _ in 0..<warmUpIterations {
            tui.requestRender(lines: frame)
        }
        let timing = measureStable(iterations: gateIterations) {
            var f = frame
            f[4] = "Line 0: Rapid refresh update"
            f[frame.count - 2] = "Line 19: Rapid refresh update"
            tui.requestRender(lines: f)
        }
        let threshold = baselineRenderMediumRapidRefreshMicros * thresholdFactor
        XCTAssertLessThan(
            timing.medianMicros, threshold,
            gateFailureMessage(label: "render-medium-rapid-refresh", observed: timing.medianMicros, threshold: threshold, unit: "μs")
        )
    }

    // MARK: - Gate 2) TranscriptRenderer.applyCore()

    func testGate_TranscriptRendererApply() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.insert(lines: [Style.user("❯ Initial prompt"), ""]))
        renderer.applyCore(.blockStart(id: "seed"))
        renderer.applyCore(.blockEnd(id: "seed", lines: ["Response text here"], footer: nil))

        let timing = measureStable(iterations: gateIterations) {
            renderer.applyCore(.blockStart(id: "stream"))
            renderer.applyCore(.blockUpdate(id: "stream", lines: ["Updated streaming content"]))
            renderer.applyCore(.blockEnd(id: "stream", lines: ["Final content"], footer: nil))
        }
        let threshold = baselineTranscriptApplyMicros * thresholdFactor
        XCTAssertLessThan(
            timing.medianMicros, threshold,
            gateFailureMessage(label: "transcript-apply", observed: timing.medianMicros, threshold: threshold, unit: "μs")
        )
    }

    // MARK: - Gate 3) 输入延迟（steer 入队）

    func testGate_InputLatency_StreamingSteer() async throws {
        let stream = AssistantMessageStream()
        let streamFn: StreamFn = { _, _, _ in stream }

        let testModel = Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )

        let agent = Agent(initialState: AgentInitialState(model: testModel), streamFn: streamFn)
        let controller = PromptController(agent: agent)

        // 进入 streaming 态
        let promptTask = Task {
            _ = try await controller.submit("hello")
        }

        var attempts = 0
        while !agent.state.isStreaming {
            await Task.yield()
            attempts += 1
            if attempts > 1000 {
                stream.end(AssistantMessage.text("timeout", stopReason: .endTurn))
                XCTFail("Timeout waiting for streaming")
                return
            }
        }

        let steerIterations = 50
        var times = [UInt64](repeating: 0, count: steerIterations)
        for i in 0..<steerIterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try? await controller.submit("steer \(i)")
            let end = DispatchTime.now().uptimeNanoseconds
            times[i] = end - start
        }

        stream.end(AssistantMessage.text("done", stopReason: .endTurn))
        try await promptTask.value

        let sorted = times.sorted()
        let medianMicros = Double(sorted[sorted.count / 2]) / 1_000.0
        let threshold = baselineSteerEnqueueMicros * thresholdFactor
        XCTAssertLessThan(
            medianMicros, threshold,
            gateFailureMessage(label: "steer-enqueue", observed: medianMicros, threshold: threshold, unit: "μs")
        )
    }
}
