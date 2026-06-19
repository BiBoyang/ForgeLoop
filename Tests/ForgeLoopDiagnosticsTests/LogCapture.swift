import Foundation

/// Thread-safe capture helper for testing log sinks.
final class LogCapture: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var captured: [String] {
        lock.lock()
        let copy = lines
        lock.unlock()
        return copy
    }
}
