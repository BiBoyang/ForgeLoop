import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli
import ForgeLoopTUI

/// STEP-028B 性能门禁测试
///
/// 基于 028A 基线值定义阈值，关键指标回退超过阈值时 XCTFail。
/// 策略：thresholdFactor 初始为 2.0（non-blocking，允许 200% 偏差），
/// 后续随基线稳定逐步收紧至 1.1（10% 回退告警）。
///
/// 基线来源：PerformanceBaselineTests 在本地 macOS arm64 环境的典型输出。
@MainActor
final class PerformanceGateTests: XCTestCase {

    // MARK: - 阈值配置

    /// 当前阈值系数。2.0 = non-blocking；1.1 = blocking（10% 回退告警）。
    private let thresholdFactor: Double = 2.0

    /// Gate 采样迭代次数（比基线少，追求速度）。
    private let gateIterations = 100

    // MARK: - 028A 基线常量（单位与阈值一致）

    /// render-small-first 基线（单位：微秒）。
    /// 2026-04-24 当前实现（安全 stdout + streaming transcript planner）实测约 40~42μs。
    private let baselineRenderSmallFirstMicros: Double = 45.0

    /// render-medium-first 基线（单位：微秒）。
    /// 2026-04-24 当前实现实测约 275~330μs。
    private let baselineRenderMediumFirstMicros: Double = 300.0

    /// render-large-first 基线（单位：毫秒）。
    private let baselineRenderLargeFirstMillis: Double = 10.0

    /// transcript-apply 基线（单位：微秒）。
    private let baselineTranscriptApplyMicros: Double = 10.0

    /// steer-enqueue 基线（单位：微秒）。
    private let baselineSteerEnqueueMicros: Double = 500.0

    // MARK: - 测量辅助

    private struct Timing {
        let avgNanos: UInt64
        var avgMicros: Double { Double(avgNanos) / 1_000.0 }
        var avgMillis: Double { Double(avgNanos) / 1_000_000.0 }
    }

    private func measure(iterations: Int, _ block: () -> Void) -> Timing {
        var times = [UInt64](repeating: 0, count: iterations)
        for i in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let end = DispatchTime.now().uptimeNanoseconds
            times[i] = end - start
        }
        let total = times.reduce(0, +)
        return Timing(avgNanos: total / UInt64(iterations))
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
        let timing = measure(iterations: gateIterations) {
            tui.requestRender(lines: frame)
        }
        let threshold = baselineRenderSmallFirstMicros * thresholdFactor
        XCTAssertLessThan(
            timing.avgMicros, threshold,
            "render-small-first exceeded gate: avg=\(timing.avgMicros)μs, threshold=\(threshold)μs"
        )
    }

    func testGate_RenderMediumFirst() {
        let tui = TUI()
        let frame = makeMediumFrame()
        let timing = measure(iterations: gateIterations) {
            tui.requestRender(lines: frame)
        }
        let threshold = baselineRenderMediumFirstMicros * thresholdFactor
        XCTAssertLessThan(
            timing.avgMicros, threshold,
            "render-medium-first exceeded gate: avg=\(timing.avgMicros)μs, threshold=\(threshold)μs"
        )
    }

    func testGate_RenderLargeFirst() {
        let tui = TUI()
        let frame = makeLargeFrame()
        let timing = measure(iterations: gateIterations) {
            tui.requestRender(lines: frame)
        }
        let threshold = baselineRenderLargeFirstMillis * thresholdFactor
        XCTAssertLessThan(
            timing.avgMillis, threshold,
            "render-large-first exceeded gate: avg=\(timing.avgMillis)ms, threshold=\(threshold)ms"
        )
    }

    // MARK: - Gate 2) TranscriptRenderer.applyCore()

    func testGate_TranscriptRendererApply() {
        let renderer = TranscriptRenderer()
        renderer.applyCore(.insert(lines: [Style.user("❯ Initial prompt"), ""]))
        renderer.applyCore(.blockStart(id: "seed"))
        renderer.applyCore(.blockEnd(id: "seed", lines: ["Response text here"], footer: nil))

        let timing = measure(iterations: gateIterations) {
            renderer.applyCore(.blockStart(id: "stream"))
            renderer.applyCore(.blockUpdate(id: "stream", lines: ["Updated streaming content"]))
            renderer.applyCore(.blockEnd(id: "stream", lines: ["Final content"], footer: nil))
        }
        let threshold = baselineTranscriptApplyMicros * thresholdFactor
        XCTAssertLessThan(
            timing.avgMicros, threshold,
            "transcript-apply exceeded gate: avg=\(timing.avgMicros)μs, threshold=\(threshold)μs"
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

        let total = times.reduce(0, +)
        let avgMicros = Double(total) / Double(steerIterations) / 1_000.0
        let threshold = baselineSteerEnqueueMicros * thresholdFactor
        XCTAssertLessThan(
            avgMicros, threshold,
            "steer-enqueue exceeded gate: avg=\(avgMicros)μs, threshold=\(threshold)μs"
        )
    }

}
