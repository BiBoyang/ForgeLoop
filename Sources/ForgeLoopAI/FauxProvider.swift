import Foundation

public final class FauxProvider: APIProvider, @unchecked Sendable {
    public let api: String
    private let tokenDelayNanos: UInt64

    public init(api: String = "faux", tokenDelayNanos: UInt64 = 30_000_000) {
        self.api = api
        self.tokenDelayNanos = tokenDelayNanos
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached { [tokenDelayNanos] in
            let answer = Self.buildAnswer(context: context)
            var partial = AssistantMessage(content: [.text(TextContent(text: ""))], stopReason: .endTurn)
            out.push(.start(partial: partial))
            out.push(.textStart(contentIndex: 0, partial: partial))

            func emitAbortIfNeeded() -> Bool {
                guard options?.cancellation?.isCancelled == true else { return false }
                let aborted = AssistantMessage(
                    content: [.text(TextContent(text: partialText(from: partial)))],
                    stopReason: .aborted,
                    errorMessage: "Request was aborted"
                )
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return true
            }

            for chunk in Self.chunk(answer, size: 6) {
                if emitAbortIfNeeded() { return }
                let merged = partialText(from: partial) + chunk
                partial = AssistantMessage(content: [.text(TextContent(text: merged))], stopReason: .endTurn)
                out.push(.textDelta(contentIndex: 0, delta: chunk, partial: partial))
                try? await Task.sleep(nanoseconds: tokenDelayNanos)
            }

            if emitAbortIfNeeded() { return }

            let finalText = partialText(from: partial)
            let final = AssistantMessage(content: [.text(TextContent(text: finalText))], stopReason: .endTurn)
            out.push(.textEnd(contentIndex: 0, content: finalText, partial: final))
            out.push(.done(reason: .endTurn, message: final))
            out.end(final)
        }
        return out
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
