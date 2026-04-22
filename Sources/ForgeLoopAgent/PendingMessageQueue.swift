import Foundation
import ForgeLoopAI

public final class PendingMessageQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [Message] = []

    public init() {}

    public func enqueue(_ message: Message) {
        lock.withLock { messages.append(message) }
    }

    public func drain() -> [Message] {
        lock.withLock {
            let drained = messages
            messages.removeAll()
            return drained
        }
    }

    public func snapshot() -> [Message] {
        lock.withLock { Array(messages) }
    }

    public func clear() {
        lock.withLock { messages.removeAll() }
    }

    public func prepend(contentsOf newMessages: [Message]) {
        lock.withLock { messages = newMessages + messages }
    }
}
