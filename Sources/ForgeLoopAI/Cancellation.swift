import Foundation

public final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    private var reasonValue: String?
    private var handlers: [@Sendable (String?) -> Void] = []

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { _isCancelled }
    }

    public var reason: String? {
        lock.withLock { reasonValue }
    }

    public func cancel(reason: String? = nil) {
        let callbacks: [@Sendable (String?) -> Void] = lock.withLock {
            guard !_isCancelled else { return [] }
            _isCancelled = true
            reasonValue = reason
            let out = handlers
            handlers.removeAll()
            return out
        }
        for callback in callbacks {
            callback(reason)
        }
    }

    public func onCancel(_ callback: @escaping @Sendable (String?) -> Void) {
        let fireNow: String? = lock.withLock {
            if _isCancelled { return reasonValue }
            handlers.append(callback)
            return nil
        }
        if fireNow != nil {
            callback(fireNow)
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
