import XCTest
import ForgeLoopTUI

/// 线程安全的帧收集器，用于测试 RenderLoop 的回调。
private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [[String]] = []

    func append(_ frame: [String]) {
        lock.withLock {
            _frames.append(frame)
        }
    }

    var frames: [[String]] {
        lock.withLock { _frames }
    }

    var count: Int {
        lock.withLock { _frames.count }
    }

    func clear() {
        lock.withLock { _frames.removeAll() }
    }
}

@MainActor
final class RenderLoopTests: XCTestCase {

    // MARK: - 1) 连续 submit(.normal) 只触发一次渲染，且为最后一帧

    func testNormalFramesCoalescedToLast() async {
        let collector = FrameCollector()
        let loop = RenderLoop(tickIntervalNanoseconds: 50_000_000) { frame in
            collector.append(frame)
        }

        loop.submit(frame: ["frame1"], priority: .normal)
        loop.submit(frame: ["frame2"], priority: .normal)
        loop.submit(frame: ["frame3"], priority: .normal)

        // Wait for tick (50ms + margin)
        try? await Task.sleep(nanoseconds: 80_000_000)

        loop.stop()

        XCTAssertEqual(collector.count, 1, "Should render only once")
        XCTAssertEqual(collector.frames.first, ["frame3"], "Should render last frame")
    }

    // MARK: - 2) submit(.normal) 等待 tick 后才渲染

    func testNormalFrameWaitsForTick() async {
        let collector = FrameCollector()
        let loop = RenderLoop(tickIntervalNanoseconds: 100_000_000) { frame in
            collector.append(frame)
        }

        loop.submit(frame: ["normal"], priority: .normal)

        // Immediately after submit: not yet rendered
        XCTAssertEqual(collector.count, 0, "Should not render immediately")

        // Wait for tick
        try? await Task.sleep(nanoseconds: 150_000_000)

        loop.stop()

        XCTAssertEqual(collector.count, 1, "Should render after tick")
        XCTAssertEqual(collector.frames.first, ["normal"])
    }

    // MARK: - 3) submit(.immediate) 不等待 tick，立刻渲染

    func testImmediateFrameRendersWithoutDelay() async {
        let collector = FrameCollector()
        let loop = RenderLoop(tickIntervalNanoseconds: 1_000_000_000) { frame in // 1s tick
            collector.append(frame)
        }

        loop.submit(frame: ["immediate"], priority: .immediate)

        // Should render right away without waiting for tick
        XCTAssertEqual(collector.count, 1, "Should render immediately")
        XCTAssertEqual(collector.frames.first, ["immediate"])

        loop.stop()
    }

    // MARK: - 4) immediate 不启动 timer（后续 normal 仍需等待 tick）

    func testImmediateDoesNotStartTimer() async {
        let collector = FrameCollector()
        let loop = RenderLoop(tickIntervalNanoseconds: 100_000_000) { frame in
            collector.append(frame)
        }

        loop.submit(frame: ["immediate"], priority: .immediate)
        XCTAssertEqual(collector.count, 1)

        // Subsequent normal should still wait for tick
        loop.submit(frame: ["normal"], priority: .normal)
        XCTAssertEqual(collector.count, 1, "Timer not started by immediate")

        try? await Task.sleep(nanoseconds: 150_000_000)

        loop.stop()

        XCTAssertEqual(collector.count, 2)
        XCTAssertEqual(collector.frames[1], ["normal"])
    }

    // MARK: - 5) normal 期间 immediate 立即 flush 当前最新帧

    func testImmediateDuringNormalFlush() async {
        let collector = FrameCollector()
        let loop = RenderLoop(tickIntervalNanoseconds: 100_000_000) { frame in
            collector.append(frame)
        }

        loop.submit(frame: ["normal1"], priority: .normal)
        loop.submit(frame: ["normal2"], priority: .normal)

        // Immediate should flush current pending frame right away
        loop.submit(frame: ["urgent"], priority: .immediate)

        XCTAssertEqual(collector.count, 1)
        XCTAssertEqual(collector.frames[0], ["urgent"])

        // Wait for original tick to ensure no extra render
        try? await Task.sleep(nanoseconds: 150_000_000)

        loop.stop()

        XCTAssertEqual(collector.count, 1, "No extra render from old tick")
    }

    // MARK: - 6) stop() 取消 timer，后续 submit 被忽略

    func testStopCancelsTimerAndIgnoresSubsequentSubmits() async {
        let collector = FrameCollector()
        let loop = RenderLoop(tickIntervalNanoseconds: 50_000_000) { frame in
            collector.append(frame)
        }

        loop.submit(frame: ["before"], priority: .normal)
        loop.stop()

        // After stop, submits should be ignored
        loop.submit(frame: ["after1"], priority: .normal)
        loop.submit(frame: ["after2"], priority: .immediate)

        // Wait to ensure no late render
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Nothing should have been rendered after stop
        XCTAssertEqual(collector.count, 0, "Stopped loop should not render")
    }

    // MARK: - 7) stop() 后 timer 不再触发

    func testStopPreventsPendingRender() async {
        let collector = FrameCollector()
        let loop = RenderLoop(tickIntervalNanoseconds: 50_000_000) { frame in
            collector.append(frame)
        }

        loop.submit(frame: ["pending"], priority: .normal)
        loop.stop()

        // Wait past the tick time
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(collector.count, 0, "Pending frame should be discarded by stop")
    }

    // MARK: - 8) 多 tick 周期：每次 tick 渲染一次

    func testMultipleTicksRenderOncePerTick() async {
        let collector = FrameCollector()
        let loop = RenderLoop(tickIntervalNanoseconds: 50_000_000) { frame in
            collector.append(frame)
        }

        loop.submit(frame: ["tick1"], priority: .normal)
        try? await Task.sleep(nanoseconds: 80_000_000)

        loop.submit(frame: ["tick2"], priority: .normal)
        try? await Task.sleep(nanoseconds: 80_000_000)

        loop.stop()

        XCTAssertEqual(collector.count, 2)
        XCTAssertEqual(collector.frames[0], ["tick1"])
        XCTAssertEqual(collector.frames[1], ["tick2"])
    }

    // MARK: - 9) 空闲后自动停表，后续 normal 需等待完整 tick

    func testTimerAutoStopsWhenIdleAndRestartsOnNextNormalSubmit() async {
        let collector = FrameCollector()
        let loop = RenderLoop(tickIntervalNanoseconds: 100_000_000) { frame in
            collector.append(frame)
        }

        // First normal frame: render at first tick.
        loop.submit(frame: ["first"], priority: .normal)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(collector.count, 1)

        // If old timer kept running, second frame would flush around +50ms.
        loop.submit(frame: ["second"], priority: .normal)
        try? await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(collector.count, 1, "Second frame should still wait for a full tick after restart")

        // Wait past a full tick from second submit.
        try? await Task.sleep(nanoseconds: 60_000_000)
        loop.stop()

        XCTAssertEqual(collector.count, 2)
        XCTAssertEqual(collector.frames[1], ["second"])
    }
}
