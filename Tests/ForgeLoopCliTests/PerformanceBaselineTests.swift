import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli
@testable import ForgeLoopTUI

/// STEP-028A 性能基线测试
///
/// 采集 3 类指标：渲染耗时、输入延迟、长输出吞吐。
/// 仅测量现状，不引入业务行为变化。
/// 每个指标独立采样，结果以纳秒/微秒/毫秒为单位输出。
@MainActor
final class PerformanceBaselineTests: XCTestCase {

    // MARK: - 常量与采样配置

    /// 渲染采样：每个场景迭代次数（追求稳定均值）
    private let renderIterations = 500

    /// 输入延迟采样：迭代次数
    private let inputLatencyIterations = 100

    /// 长输出吞吐采样：messageUpdate 次数 × 每更新字符数
    private let throughputUpdateCount = 50
    private let throughputCharsPerUpdate = 20

    /// 大帧行数（STEP-023 目标场景）
    private let largeFrameLines = 120

    /// 统计结果收集
    private struct Sample: CustomStringConvertible {
        let label: String
        let iterations: Int
        let totalNanos: UInt64
        let minNanos: UInt64
        let maxNanos: UInt64
        let p50Nanos: UInt64
        let p95Nanos: UInt64

        var avgNanos: UInt64 { totalNanos / UInt64(iterations) }
        var avgMicros: Double { Double(avgNanos) / 1_000.0 }
        var avgMillis: Double { Double(avgNanos) / 1_000_000.0 }
        var p95Micros: Double { Double(p95Nanos) / 1_000.0 }
        var p95Millis: Double { Double(p95Nanos) / 1_000_000.0 }

        var description: String {
            String(
                format: "%@: avg=%.3f ms (%.1f μs) | p95=%.3f ms | min=%.1f μs | max=%.3f ms | n=%d",
                label, avgMillis, avgMicros, p95Millis, Double(minNanos) / 1_000.0, Double(maxNanos) / 1_000_000.0, iterations
            )
        }

        var reportLine: String {
            String(
                format: "| %@ | %.3f ms | %.3f ms | %d |",
                label, avgMillis, p95Millis, iterations
            )
        }
    }

    private func measureSamples(
        label: String,
        iterations: Int,
        _ block: () -> Void
    ) -> Sample {
        var times = [UInt64](repeating: 0, count: iterations)
        for i in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let end = DispatchTime.now().uptimeNanoseconds
            times[i] = end - start
        }
        let sorted = times.sorted()
        let total = times.reduce(0, +)
        let p50 = sorted[sorted.count / 2]
        let p95Idx = Int(Double(sorted.count) * 0.95)
        let p95 = sorted[min(p95Idx, sorted.count - 1)]
        return Sample(
            label: label,
            iterations: iterations,
            totalNanos: total,
            minNanos: sorted.first!,
            maxNanos: sorted.last!,
            p50Nanos: p50,
            p95Nanos: p95
        )
    }

    // MARK: - 辅助：构造不同规模帧

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
        for i in 0..<largeFrameLines {
            lines.append("Line \(i): " + String(repeating: "x", count: 60))
        }
        lines.append(contentsOf: ["", Style.dimmed("model: faux-coding-model · local scaffold | streaming | 5 tools pending")])
        return lines
    }

    // MARK: - 1) 渲染耗时

    /// 1.1 小帧首帧渲染（首次清屏+全量绘制）
    func testBaseline_RenderSmallFrame_First() throws {
        let tui = TUI()
        let frame = makeSmallFrame()
        let sample = measureSamples(label: "render-small-first", iterations: renderIterations) {
            tui.requestRender(lines: frame)
        }
        print("\n[BASELINE] \(sample)")
        XCTAssertLessThan(sample.avgMillis, 5.0, "Small frame first render should be fast")
    }

    /// 1.2 小帧增量渲染（内容无变化）
    func testBaseline_RenderSmallFrame_NoChange() throws {
        let tui = TUI()
        let frame = makeSmallFrame()
        tui.requestRender(lines: frame)
        let sample = measureSamples(label: "render-small-nochange", iterations: renderIterations) {
            tui.requestRender(lines: frame)
        }
        print("\n[BASELINE] \(sample)")
        // 无变化时提前返回，应该极快
        XCTAssertLessThan(sample.avgMicros, 50.0, "No-change render should be nearly instant")
    }

    /// 1.3 小帧增量渲染（部分变化）
    func testBaseline_RenderSmallFrame_PartialUpdate() throws {
        let tui = TUI()
        var frame = makeSmallFrame()
        tui.requestRender(lines: frame)
        frame[4] = "Updated content line here"
        let sample = measureSamples(label: "render-small-partial", iterations: renderIterations) {
            tui.requestRender(lines: frame)
        }
        print("\n[BASELINE] \(sample)")
        XCTAssertLessThan(sample.avgMillis, 5.0, "Small partial update should be fast")
    }

    /// 1.4 中帧首帧渲染
    func testBaseline_RenderMediumFrame_First() throws {
        let tui = TUI()
        let frame = makeMediumFrame()
        let sample = measureSamples(label: "render-medium-first", iterations: renderIterations) {
            tui.requestRender(lines: frame)
        }
        print("\n[BASELINE] \(sample)")
        XCTAssertLessThan(sample.avgMillis, 10.0, "Medium frame first render should be under 10ms")
    }

    /// 1.5 中帧增量渲染（追加一行）
    func testBaseline_RenderMediumFrame_AppendOne() throws {
        let tui = TUI()
        var frame = makeMediumFrame()
        tui.requestRender(lines: frame)
        frame.insert("Appended line", at: frame.count - 2)
        let sample = measureSamples(label: "render-medium-append", iterations: renderIterations) {
            tui.requestRender(lines: frame)
        }
        print("\n[BASELINE] \(sample)")
        XCTAssertLessThan(sample.avgMillis, 10.0, "Medium frame append should be under 10ms")
    }

    /// 1.6 大帧首帧渲染（120 行，STEP-023 目标场景）
    func testBaseline_RenderLargeFrame_First() throws {
        let tui = TUI()
        let frame = makeLargeFrame()
        let sample = measureSamples(label: "render-large-first", iterations: renderIterations) {
            tui.requestRender(lines: frame)
        }
        print("\n[BASELINE] \(sample)")
        // 基线采集：记录现状，不设严格断言，仅记录
        XCTAssertLessThan(sample.avgMillis, 50.0, "Large frame first render baseline")
    }

    /// 1.7 大帧增量渲染（streaming 追加更新）
    func testBaseline_RenderLargeFrame_StreamingAppend() throws {
        let tui = TUI()
        var frame = makeLargeFrame()
        tui.requestRender(lines: frame)
        frame.insert("Streaming appended line", at: frame.count - 2)
        let sample = measureSamples(label: "render-large-stream-append", iterations: renderIterations) {
            tui.requestRender(lines: frame)
        }
        print("\n[BASELINE] \(sample)")
        XCTAssertLessThan(sample.avgMillis, 50.0, "Large streaming append baseline")
    }

    /// 1.8 TranscriptRenderer.applyCore() 独立耗时（不含 TUI 输出）
    func testBaseline_TranscriptRendererApply() throws {
        let renderer = TranscriptRenderer()
        // 先构建一些 transcript 状态
        renderer.applyCore(.insert(lines: [Style.user("❯ Initial prompt"), ""]))
        renderer.applyCore(.blockStart(id: "seed"))
        renderer.applyCore(.blockEnd(id: "seed", lines: ["Response text here"], footer: nil))

        let sample = measureSamples(label: "transcript-apply", iterations: renderIterations) {
            renderer.applyCore(.blockStart(id: "stream"))
            renderer.applyCore(.blockUpdate(id: "stream", lines: ["Updated streaming content"]))
            renderer.applyCore(.blockEnd(id: "stream", lines: ["Final content"], footer: nil))
        }
        print("\n[BASELINE] \(sample)")
        XCTAssertLessThan(sample.avgMicros, 100.0, "TranscriptRenderer.applyCore should be sub-millisecond")
    }

    // MARK: - 2) 输入延迟

    /// 2.1 idle 态 prompt 提交延迟（端到端：submit -> agent 开始 streaming）
    func testBaseline_InputLatency_IdlePrompt() async throws {
        _ = await registerBuiltins(sourceId: "test-baseline-input")
        defer {
            Task { await APIRegistry.shared.unregisterSource("test-baseline-input") }
        }

        let testModel = Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )

        var latencies = [UInt64](repeating: 0, count: inputLatencyIterations)

        for i in 0..<inputLatencyIterations {
            let agent = Agent(initialState: AgentInitialState(model: testModel))
            let controller = PromptController(agent: agent)

            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await controller.submit("test \(i)")
            let end = DispatchTime.now().uptimeNanoseconds

            latencies[i] = end - start
        }

        let sample = makeSample(label: "input-latency-idle-prompt", values: latencies)
        print("\n[BASELINE] \(sample)")
        // 基线记录，faux provider 的 prompt 包含完整生命周期
    }

    /// 2.2 streaming 态 steer 提交延迟（纯入队，不等待）
    func testBaseline_InputLatency_StreamingSteer() async throws {
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

        // 先进入 streaming 态
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

        var latencies = [UInt64](repeating: 0, count: inputLatencyIterations)

        for i in 0..<inputLatencyIterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try? await controller.submit("steer \(i)")
            let end = DispatchTime.now().uptimeNanoseconds
            latencies[i] = end - start
        }

        stream.end(AssistantMessage.text("done", stopReason: .endTurn))
        try await promptTask.value

        let sample = makeSample(label: "input-latency-streaming-steer", values: latencies)
        print("\n[BASELINE] \(sample)")
        // steer 入队应该是微秒级
        XCTAssertLessThan(sample.avgMicros, 500.0, "Steer enqueue should be sub-millisecond")
    }

    // MARK: - 3) 长输出吞吐

    /// 3.1 大量 messageUpdate 累积渲染吞吐（字符/秒）
    func testBaseline_LongOutputThroughput_Renderer() throws {
        let renderer = TranscriptRenderer()
        let totalChars = throughputUpdateCount * throughputCharsPerUpdate

        let start = DispatchTime.now().uptimeNanoseconds

        renderer.applyCore(.blockStart(id: "stream"))
        for _ in 0..<throughputUpdateCount {
            let text = String(repeating: "a", count: throughputCharsPerUpdate)
            renderer.applyCore(.blockUpdate(id: "stream", lines: [text]))
        }
        renderer.applyCore(.blockEnd(id: "stream", lines: [String(repeating: "a", count: throughputCharsPerUpdate)], footer: nil))

        let end = DispatchTime.now().uptimeNanoseconds
        let elapsedNanos = end - start
        let elapsedSec = Double(elapsedNanos) / 1_000_000_000.0
        let charsPerSec = Double(totalChars) / elapsedSec

        let sample = Sample(
            label: "throughput-renderer (\(totalChars) chars / \(throughputUpdateCount) updates)",
            iterations: 1,
            totalNanos: elapsedNanos,
            minNanos: elapsedNanos,
            maxNanos: elapsedNanos,
            p50Nanos: elapsedNanos,
            p95Nanos: elapsedNanos
        )

        print("\n[BASELINE] \(sample)")
        print("[BASELINE] throughput-renderer: \(String(format: "%.1f", charsPerSec)) chars/sec")
        print("[BASELINE] throughput-renderer: per-update avg = \(String(format: "%.3f", elapsedSec * 1000.0 / Double(throughputUpdateCount))) ms")
    }

    /// 3.2 大量 messageUpdate + TUI 渲染吞吐
    func testBaseline_LongOutputThroughput_FullPipeline() throws {
        let renderer = TranscriptRenderer()
        let tui = TUI()
        let totalChars = throughputUpdateCount * throughputCharsPerUpdate

        // 预热：先渲染一个初始帧
        let header: [String] = [
            Style.header("✻ forgeloop replica"),
            Style.dimmed("  faux-coding-model · local scaffold"),
            Style.dimmed("  /Users/demo"),
            "",
        ]
        let statusBar = Style.dimmed("model: faux-coding-model · local scaffold | streaming")

        let start = DispatchTime.now().uptimeNanoseconds

        renderer.applyCore(.blockStart(id: "stream"))
        for _ in 0..<throughputUpdateCount {
            let text = String(repeating: "a", count: throughputCharsPerUpdate)
            renderer.applyCore(.blockUpdate(id: "stream", lines: [text]))

            // 模拟完整 pipeline：renderer -> frame -> TUI
            let frame = header + renderer.transcriptLines + ["", statusBar]
            tui.requestRender(lines: frame)
        }
        renderer.applyCore(.blockEnd(id: "stream", lines: [String(repeating: "a", count: throughputCharsPerUpdate)], footer: nil))

        let end = DispatchTime.now().uptimeNanoseconds
        let elapsedNanos = end - start
        let elapsedSec = Double(elapsedNanos) / 1_000_000_000.0
        let charsPerSec = Double(totalChars) / elapsedSec

        let sample = Sample(
            label: "throughput-full-pipeline (\(totalChars) chars / \(throughputUpdateCount) updates)",
            iterations: 1,
            totalNanos: elapsedNanos,
            minNanos: elapsedNanos,
            maxNanos: elapsedNanos,
            p50Nanos: elapsedNanos,
            p95Nanos: elapsedNanos
        )

        print("\n[BASELINE] \(sample)")
        print("[BASELINE] throughput-full-pipeline: \(String(format: "%.1f", charsPerSec)) chars/sec")
        print("[BASELINE] throughput-full-pipeline: per-update avg = \(String(format: "%.3f", elapsedSec * 1000.0 / Double(throughputUpdateCount))) ms")
    }

    // MARK: - 4) 综合报告输出

    /// 汇总打印所有基线指标（便于 CI/脚本捕获）
    func testBaseline_ReportAllMetrics() async throws {
        print("\n========== STEP-028A 性能基线报告 ==========")
        print("采集时间: \(Date())")
        print("环境: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("CPU: \(ProcessInfo.processInfo.processorCount) cores")
        print("")
        print("采样配置:")
        print("  - 渲染迭代次数: \(renderIterations)")
        print("  - 输入延迟迭代次数: \(inputLatencyIterations)")
        print("  - 长输出更新次数: \(throughputUpdateCount) × \(throughputCharsPerUpdate) chars")
        print("")
        print("| 指标 | 均值 | p95 | 迭代次数 |")
        print("|------|------|-----|---------|")

        // 渲染指标
        let tui = TUI()
        var samples: [Sample] = []

        // small first
        do {
            let frame = makeSmallFrame()
            let s = measureSamples(label: "render-small-first", iterations: renderIterations) {
                tui.requestRender(lines: frame)
            }
            samples.append(s)
            print(s.reportLine)
        }

        // small nochange (fresh tui)
        do {
            let tui2 = TUI()
            let frame = makeSmallFrame()
            tui2.requestRender(lines: frame)
            let s = measureSamples(label: "render-small-nochange", iterations: renderIterations) {
                tui2.requestRender(lines: frame)
            }
            samples.append(s)
            print(s.reportLine)
        }

        // medium first
        do {
            let tui3 = TUI()
            let frame = makeMediumFrame()
            let s = measureSamples(label: "render-medium-first", iterations: renderIterations) {
                tui3.requestRender(lines: frame)
            }
            samples.append(s)
            print(s.reportLine)
        }

        // large first
        do {
            let tui4 = TUI()
            let frame = makeLargeFrame()
            let s = measureSamples(label: "render-large-first", iterations: renderIterations) {
                tui4.requestRender(lines: frame)
            }
            samples.append(s)
            print(s.reportLine)
        }

        // transcript apply
        do {
            let renderer = TranscriptRenderer()
            renderer.applyCore(.insert(lines: [Style.user("❯ x"), ""]))
            renderer.applyCore(.blockStart(id: "seed"))
            renderer.applyCore(.blockEnd(id: "seed", lines: ["y"], footer: nil))
            let s = measureSamples(label: "transcript-apply", iterations: renderIterations) {
                renderer.applyCore(.blockStart(id: "stream"))
                renderer.applyCore(.blockUpdate(id: "stream", lines: ["z"]))
                renderer.applyCore(.blockEnd(id: "stream", lines: ["z"], footer: nil))
            }
            samples.append(s)
            print(s.reportLine)
        }

        print("\n基线采集完成。以上数据用于 STEP-023~027 改造前后对比。")
        print("阈值约定: 相比本基线，关键指标回退 >10% 触发告警。")
        print("=========================================")

        XCTAssertFalse(samples.isEmpty, "Should have collected baseline samples")
    }

    // MARK: - 辅助方法

    private func makeSample(label: String, values: [UInt64]) -> Sample {
        let sorted = values.sorted()
        let total = values.reduce(0, +)
        let p50 = sorted[sorted.count / 2]
        let p95Idx = Int(Double(sorted.count) * 0.95)
        let p95 = sorted[min(p95Idx, sorted.count - 1)]
        return Sample(
            label: label,
            iterations: values.count,
            totalNanos: total,
            minNanos: sorted.first ?? 0,
            maxNanos: sorted.last ?? 0,
            p50Nanos: p50,
            p95Nanos: p95
        )
    }
}
