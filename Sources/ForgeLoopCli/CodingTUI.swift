import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@MainActor
func runCodingTUIInternal(
    model: Model,
    cwd: String
) async throws {
    let session = await CodingTUISession(model: model, cwd: cwd)

    let keyEvents: AsyncStream<KeyEvent>
    let inputReader: InputReader?
    if session.tui.isTTY {
        let (stream, continuation) = AsyncStream.makeStream(of: KeyEvent.self)
        let reader = InputReader { events in
            for event in events {
                continuation.yield(event)
            }
        }
        do {
            try reader.start()
            inputReader = reader
            keyEvents = stream
        } catch {
            continuation.finish()
            inputReader = nil
            keyEvents = AsyncStream { $0.finish() }
        }
    } else {
        inputReader = nil
        keyEvents = AsyncStream { $0.finish() }
    }
    defer { inputReader?.stop() }

    // 后台 queue 监视
    session.bgMonitor = Task { @MainActor in
        while !Task.isCancelled {
            await session.refreshQueueLines()
            session.renderFrame()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // 首帧渲染
    session.renderFrame(priority: .immediate)

    eventLoop: for await event in keyEvents {
        for resolved in session.keyResolver.feed(event) {
            if !(await session.handleResolvedKey(resolved)) {
                break eventLoop
            }
        }
        for resolved in session.keyResolver.tick() {
            if !(await session.handleResolvedKey(resolved)) {
                break eventLoop
            }
        }
    }

    session.saveLastSession()
    session.bgMonitor?.cancel()
    if let renderLoop = session.renderLoop { renderLoop.stop() }
}
