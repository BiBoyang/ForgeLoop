import Foundation

/// 统一渲染调度器：16ms 合帧 + 关键场景即时刷新。
///
/// 通过 `submit(frame:priority:)` 提交帧：
/// - `.normal`：加入合帧队列，当前 tick 内多次提交只保留最后一帧。
/// - `.immediate`：立即渲染当前最新帧，不等待 tick。
///
/// timer 在每个 tick 触发 flush；flush 后若队列为空则停止 timer，避免空转。
public final class RenderLoop: @unchecked Sendable {
    public enum Priority: Sendable, Equatable {
        case normal
        case immediate
    }

    private let lock = NSLock()
    private let tickInterval: UInt64
    private let render: @Sendable ([String]) -> Void
    private var pendingFrame: [String]?
    private var timerTask: Task<Void, Never>?
    private var isStopped = false

    public init(
        tickIntervalNanoseconds: UInt64 = 16_000_000,
        render: @escaping @Sendable ([String]) -> Void
    ) {
        self.tickInterval = tickIntervalNanoseconds
        self.render = render
    }

    /// 提交一帧。`.normal` 进入合帧队列；`.immediate` 立即渲染。
    public func submit(frame: [String], priority: Priority = .normal) {
        lock.withLock {
            guard !isStopped else { return }
            pendingFrame = frame
        }
        switch priority {
        case .immediate:
            flush()
        case .normal:
            startTimerIfNeeded()
        }
    }

    /// 停止调度器，取消 timer，丢弃 pending frame。
    /// 停止后再次调用 `submit` 无效果。
    public func stop() {
        let task: Task<Void, Never>? = lock.withLock {
            let current = timerTask
            timerTask = nil
            return current
        }
        task?.cancel()
        lock.withLock {
            isStopped = true
            pendingFrame = nil
        }
    }

    // MARK: - Private

    private func startTimerIfNeeded() {
        let shouldStart = lock.withLock {
            !isStopped && timerTask == nil
        }
        guard shouldStart else { return }

        let interval = tickInterval
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self else { return }
                if !self.flushAndShouldContinue() {
                    return
                }
            }
        }

        lock.withLock {
            if isStopped || timerTask != nil {
                task.cancel()
            } else {
                timerTask = task
            }
        }
    }

    private func flush() {
        let frame: [String]? = lock.withLock {
            let f = pendingFrame
            pendingFrame = nil
            return f
        }
        guard let frame else { return }
        render(frame)
        _ = stopTimerIfIdle(cancelTask: true)
    }

    private func flushAndShouldContinue() -> Bool {
        let frame: [String]? = lock.withLock {
            let f = pendingFrame
            pendingFrame = nil
            return f
        }
        if let frame {
            render(frame)
        }
        return !stopTimerIfIdle(cancelTask: false)
    }

    private func stopTimerIfIdle(cancelTask: Bool) -> Bool {
        let (shouldStop, taskToCancel): (Bool, Task<Void, Never>?) = lock.withLock {
            guard isStopped || pendingFrame == nil else {
                return (false, nil)
            }
            let current = cancelTask ? timerTask : nil
            timerTask = nil
            return (true, current)
        }
        taskToCancel?.cancel()
        return shouldStop
    }
}
