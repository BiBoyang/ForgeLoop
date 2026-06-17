import Foundation

/// Thread-safe counter for tracking stream invocation counts.
public actor StreamCallCounter {
    public private(set) var count: Int = 0

    public init() {}

    @discardableResult
    public func increment() -> Int {
        count += 1
        return count
    }

    public func value() -> Int {
        count
    }

    public func reset() {
        count = 0
    }
}
