import Foundation

public final class AssistantMessageStream: AsyncSequence, Sendable {
    public typealias Element = AssistantMessageEvent

    private let state = StreamState()

    public init() {}

    public func push(_ event: AssistantMessageEvent) {
        state.push(event)
    }

    public func end(_ message: AssistantMessage) {
        state.end(message)
    }

    public func result() async -> AssistantMessage {
        await state.awaitResult()
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(state: state)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let state: StreamState
        public mutating func next() async -> AssistantMessageEvent? {
            await state.nextEvent()
        }
    }
}

public final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [AssistantMessageEvent] = []
    private var eventWaiters: [CheckedContinuation<AssistantMessageEvent?, Never>] = []
    private var resultWaiters: [CheckedContinuation<AssistantMessage, Never>] = []
    private var ended = false
    private var finalMessage: AssistantMessage?

    func push(_ event: AssistantMessageEvent) {
        let waiter: CheckedContinuation<AssistantMessageEvent?, Never>? = lock.withLock {
            if ended { return nil }
            if let waiter = eventWaiters.first {
                eventWaiters.removeFirst()
                return waiter
            }
            buffer.append(event)
            return nil
        }
        waiter?.resume(returning: event)
    }

    func end(_ message: AssistantMessage) {
        let (eventWaitersToNotify, resultWaitersToNotify): (
            [CheckedContinuation<AssistantMessageEvent?, Never>],
            [CheckedContinuation<AssistantMessage, Never>]
        ) = lock.withLock {
            if ended { return ([], []) }
            ended = true
            finalMessage = message
            let ew = eventWaiters
            eventWaiters.removeAll()
            let rw = resultWaiters
            resultWaiters.removeAll()
            return (ew, rw)
        }
        for w in eventWaitersToNotify { w.resume(returning: nil) }
        for w in resultWaitersToNotify { w.resume(returning: message) }
    }

    func nextEvent() async -> AssistantMessageEvent? {
        await withCheckedContinuation { (cont: CheckedContinuation<AssistantMessageEvent?, Never>) in
            lock.withLock {
                if !buffer.isEmpty {
                    let event = buffer.removeFirst()
                    cont.resume(returning: event)
                    return
                }
                if ended {
                    cont.resume(returning: nil)
                    return
                }
                eventWaiters.append(cont)
            }
        }
    }

    func awaitResult() async -> AssistantMessage {
        await withCheckedContinuation { (cont: CheckedContinuation<AssistantMessage, Never>) in
            lock.withLock {
                if let message = finalMessage {
                    cont.resume(returning: message)
                    return
                }
                resultWaiters.append(cont)
            }
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
