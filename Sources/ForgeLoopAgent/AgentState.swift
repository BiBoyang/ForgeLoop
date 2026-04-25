import Foundation
import ForgeLoopAI

public final class AgentState: @unchecked Sendable {
    private let lock = NSLock()

    private var _systemPrompt: String
    private var _model: Model
    private var _messages: [Message]
    private var _isStreaming = false
    private var _streamingMessage: Message?
    private var _errorMessage: String?

    public init(
        systemPrompt: String,
        model: Model,
        messages: [Message]
    ) {
        self._systemPrompt = systemPrompt
        self._model = model
        self._messages = messages
    }

    public var systemPrompt: String {
        get { lock.withLock { _systemPrompt } }
        set { lock.withLock { _systemPrompt = newValue } }
    }

    public var model: Model {
        get { lock.withLock { _model } }
        set { lock.withLock { _model = newValue } }
    }

    public var messages: [Message] {
        get { lock.withLock { _messages } }
        set { lock.withLock { _messages = Array(newValue) } }
    }

    public var isStreaming: Bool {
        lock.withLock { _isStreaming }
    }

    public var streamingMessage: Message? {
        lock.withLock { _streamingMessage }
    }

    public var errorMessage: String? {
        lock.withLock { _errorMessage }
    }

    func appendMessage(_ message: Message) {
        lock.withLock { _messages.append(message) }
    }

    func setStreaming(_ value: Bool) {
        lock.withLock { _isStreaming = value }
    }

    func setStreamingMessage(_ message: Message?) {
        lock.withLock { _streamingMessage = message }
    }

    func setErrorMessage(_ error: String?) {
        lock.withLock { _errorMessage = error }
    }

    // MARK: - Auto-compact

    private var _autoCompactThreshold: Int = 24
    private var _autoCompactKeepCount: Int = 10
    private var _autoCompactMinGap: Int = 10
    private var _lastCompactedMessageCount: Int = 0

    /// 自动压缩阈值。当消息数超过此值时，在 turn 结束后自动 compact。
    public var autoCompactThreshold: Int {
        get { lock.withLock { _autoCompactThreshold } }
        set { lock.withLock { _autoCompactThreshold = newValue } }
    }

    /// 自动压缩后保留的最近消息数。
    public var autoCompactKeepCount: Int {
        get { lock.withLock { _autoCompactKeepCount } }
        set { lock.withLock { _autoCompactKeepCount = newValue } }
    }

    /// 两次 auto-compact 之间至少需要新增的消息数，防止频繁触发。
    public var autoCompactMinGap: Int {
        get { lock.withLock { _autoCompactMinGap } }
        set { lock.withLock { _autoCompactMinGap = newValue } }
    }

    /// 压缩历史上下文，保留最近 N 条消息。
    public func compact(keepLast: Int = 10) {
        lock.withLock { compactUnlocked(keepLast: keepLast) }
    }

    /// 检查消息数是否超过阈值且距离上次 compact 增长了足够多消息，若满足则执行 compact。
    /// 返回 compact 前后的消息数；若未触发或消息数未减少则返回 nil。
    public func maybeAutoCompact() -> (before: Int, after: Int)? {
        lock.withLock {
            let count = _messages.count
            guard count > _autoCompactThreshold else { return nil }
            guard count - _lastCompactedMessageCount >= _autoCompactMinGap else { return nil }
            let before = count
            compactUnlocked(keepLast: _autoCompactKeepCount)
            let after = _messages.count
            _lastCompactedMessageCount = after
            return after < before ? (before, after) : nil
        }
    }

    private func compactUnlocked(keepLast: Int) {
        if _messages.count > keepLast {
            _messages = Array(_messages.suffix(keepLast))
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
