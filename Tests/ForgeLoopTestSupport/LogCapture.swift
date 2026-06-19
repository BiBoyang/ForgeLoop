import Foundation

/// Thread-safe capture helper for testing log sinks.
public final class LogCapture: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    public init() {}

    public func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    public var captured: [String] {
        lock.lock()
        let copy = lines
        lock.unlock()
        return copy
    }
}
