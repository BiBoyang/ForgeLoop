import Foundation

public enum FauxProviderMode: Sendable {
    case text
    case toolCall(name: String, arguments: String)
    case textThenToolCall(text: String, toolName: String, toolArguments: String)
    case multipleToolCalls([(name: String, arguments: String)])
}

public final class FauxProvider: APIProvider, @unchecked Sendable {
    public let api: String
    private let tokenDelayNanos: UInt64
    public var mode: FauxProviderMode

    public init(api: String = "faux", tokenDelayNanos: UInt64 = 30_000_000, mode: FauxProviderMode = .text) {
        self.api = api
        self.tokenDelayNanos = tokenDelayNanos
        self.mode = mode
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached { [tokenDelayNanos, mode] in
            switch mode {
            case .text:
                await Self.runTextMode(context: context, options: options, output: out, tokenDelayNanos: tokenDelayNanos)
            case .toolCall(let name, let arguments):
                await Self.runToolCallMode(toolName: name, arguments: arguments, options: options, output: out)
            case .textThenToolCall(let text, let toolName, let toolArguments):
                await Self.runTextThenToolCallMode(text: text, toolName: toolName, toolArguments: toolArguments, options: options, output: out, tokenDelayNanos: tokenDelayNanos)
            case .multipleToolCalls(let tools):
                await Self.runMultipleToolCallsMode(tools: tools, options: options, output: out)
            }
        }
        return out
    }

    // MARK: - Text Mode (default, preserves existing behavior)

    private static func runTextMode(
        context: Context,
        options: StreamOptions?,
        output: AssistantMessageStream,
        tokenDelayNanos: UInt64
    ) async {
        let answer = Self.buildAnswer(context: context)
        var partial = AssistantMessage(content: [.text(TextContent(text: ""))], stopReason: .endTurn)
        output.push(.start(partial: partial))
        output.push(.textStart(contentIndex: 0, partial: partial))

        func emitAbortIfNeeded() -> Bool {
            guard options?.cancellation?.isCancelled == true else { return false }
            let aborted = AssistantMessage(
                content: [.text(TextContent(text: partialText(from: partial)))],
                stopReason: .aborted,
                errorMessage: "Request was aborted"
            )
            output.push(.error(reason: .aborted, error: aborted))
            output.end(aborted)
            return true
        }

        for chunk in Self.chunk(answer, size: 6) {
            if emitAbortIfNeeded() { return }
            let merged = partialText(from: partial) + chunk
            partial = AssistantMessage(content: [.text(TextContent(text: merged))], stopReason: .endTurn)
            output.push(.textDelta(contentIndex: 0, delta: chunk, partial: partial))
            try? await Task.sleep(nanoseconds: tokenDelayNanos)
        }

        if emitAbortIfNeeded() { return }

        let finalText = partialText(from: partial)
        let final = AssistantMessage(content: [.text(TextContent(text: finalText))], stopReason: .endTurn)
        output.push(.textEnd(contentIndex: 0, content: finalText, partial: final))
        output.push(.done(reason: .endTurn, message: final))
        output.end(final)
    }

    // MARK: - Tool Call Mode

    private static func runToolCallMode(
        toolName: String,
        arguments: String,
        options: StreamOptions?,
        output: AssistantMessageStream
    ) async {
        func emitAbortIfNeeded() -> Bool {
            guard options?.cancellation?.isCancelled == true else { return false }
            let aborted = AssistantMessage(
                content: [.toolCall(ToolCall(id: "call_faux_001", name: toolName, arguments: arguments))],
                stopReason: .aborted,
                errorMessage: "Request was aborted"
            )
            output.push(.error(reason: .aborted, error: aborted))
            output.end(aborted)
            return true
        }

        let partial = AssistantMessage(
            content: [.toolCall(ToolCall(id: "call_faux_001", name: toolName, arguments: arguments))],
            stopReason: .toolUse
        )
        output.push(.start(partial: partial))

        if emitAbortIfNeeded() { return }

        let final = AssistantMessage(
            content: [.toolCall(ToolCall(id: "call_faux_001", name: toolName, arguments: arguments))],
            stopReason: .toolUse
        )
        output.push(.done(reason: .toolUse, message: final))
        output.end(final)
    }

    // MARK: - Text Then Tool Call Mode

    private static func runTextThenToolCallMode(
        text: String,
        toolName: String,
        toolArguments: String,
        options: StreamOptions?,
        output: AssistantMessageStream,
        tokenDelayNanos: UInt64
    ) async {
        var partial = AssistantMessage(content: [.text(TextContent(text: ""))], stopReason: .endTurn)
        output.push(.start(partial: partial))
        output.push(.textStart(contentIndex: 0, partial: partial))

        func emitAbortIfNeeded() -> Bool {
            guard options?.cancellation?.isCancelled == true else { return false }
            let finalText = partialText(from: partial)
            let aborted = AssistantMessage(
                content: [
                    .text(TextContent(text: finalText)),
                    .toolCall(ToolCall(id: "call_faux_002", name: toolName, arguments: toolArguments))
                ],
                stopReason: .aborted,
                errorMessage: "Request was aborted"
            )
            output.push(.error(reason: .aborted, error: aborted))
            output.end(aborted)
            return true
        }

        for chunk in Self.chunk(text, size: 6) {
            if emitAbortIfNeeded() { return }
            let merged = partialText(from: partial) + chunk
            partial = AssistantMessage(content: [.text(TextContent(text: merged))], stopReason: .endTurn)
            output.push(.textDelta(contentIndex: 0, delta: chunk, partial: partial))
            try? await Task.sleep(nanoseconds: tokenDelayNanos)
        }

        if emitAbortIfNeeded() { return }

        let finalText = partialText(from: partial)
        let final = AssistantMessage(
            content: [
                .text(TextContent(text: finalText)),
                .toolCall(ToolCall(id: "call_faux_002", name: toolName, arguments: toolArguments))
            ],
            stopReason: .toolUse
        )
        output.push(.textEnd(contentIndex: 0, content: finalText, partial: final))
        output.push(.done(reason: .toolUse, message: final))
        output.end(final)
    }

    // MARK: - Multiple Tool Calls Mode

    private static func runMultipleToolCallsMode(
        tools: [(name: String, arguments: String)],
        options: StreamOptions?,
        output: AssistantMessageStream
    ) async {
        func emitAbortIfNeeded() -> Bool {
            guard options?.cancellation?.isCancelled == true else { return false }
            var content: [AssistantBlock] = []
            for (index, tool) in tools.enumerated() {
                content.append(.toolCall(ToolCall(id: "call_faux_\(index + 1)", name: tool.name, arguments: tool.arguments)))
            }
            let aborted = AssistantMessage(content: content, stopReason: .aborted, errorMessage: "Request was aborted")
            output.push(.error(reason: .aborted, error: aborted))
            output.end(aborted)
            return true
        }

        var content: [AssistantBlock] = []
        for (index, tool) in tools.enumerated() {
            content.append(.toolCall(ToolCall(id: "call_faux_\(index + 1)", name: tool.name, arguments: tool.arguments)))
        }
        let partial = AssistantMessage(content: content, stopReason: .toolUse)
        output.push(.start(partial: partial))

        if emitAbortIfNeeded() { return }

        let final = AssistantMessage(content: content, stopReason: .toolUse)
        output.push(.done(reason: .toolUse, message: final))
        output.end(final)
    }
}

private func partialText(from message: AssistantMessage) -> String {
    message.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }.joined()
}

extension FauxProvider {
    static func buildAnswer(context: Context) -> String {
        let input = context.messages.reversed().first { message in
            if case .user = message { return true }
            return false
        }

        if case .user(let user) = input {
            return "FauxProvider 收到：\(user.text)"
        }
        return "FauxProvider 准备就绪。"
    }

    static func chunk(_ text: String, size: Int) -> [String] {
        guard size > 0, !text.isEmpty else { return [] }
        var out: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let next = text.index(idx, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[idx..<next]))
            idx = next
        }
        return out
    }
}
