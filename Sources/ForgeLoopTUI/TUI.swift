import Foundation

public final class TUI: @unchecked Sendable {
    public init() {}

    private let lock = NSLock()

    public func requestRender(lines: [String]) {
        lock.withLock {
            let clear = "\u{1B}[2J\u{1B}[H"
            FileHandle.standardOutput.write(Data(clear.utf8))
            FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
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
