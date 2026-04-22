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

    /// 压缩历史上下文，保留最近 N 条消息。
    public func compact(keepLast: Int = 10) {
        lock.withLock {
            if _messages.count > keepLast {
                _messages = Array(_messages.suffix(keepLast))
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
