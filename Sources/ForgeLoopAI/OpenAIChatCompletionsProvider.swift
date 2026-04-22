import Foundation

public final class OpenAIChatCompletionsProvider: APIProvider, @unchecked Sendable {
    public let api: String

    private let defaultBaseURL: String
    private let defaultAPIKey: String?
    private let httpClient: any HTTPClient

    public init(
        api: String = "openai-chat-completions",
        baseURL: String = "https://api.openai.com",
        defaultAPIKey: String? = nil,
        httpClient: any HTTPClient = URLSessionHTTPClient()
    ) {
        self.api = api
        self.defaultBaseURL = baseURL
        self.defaultAPIKey = defaultAPIKey
        self.httpClient = httpClient
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        let worker = Task.detached { [self] in
            await runStream(
                model: model,
                context: context,
                options: options,
                output: out
            )
        }
        options?.cancellation?.onCancel { _ in
            worker.cancel()
        }
        return out
    }

    private func runStream(
        model: Model,
        context: Context,
        options: StreamOptions?,
        output: AssistantMessageStream
    ) async {
        var partial = AssistantMessage(
            content: [.text(TextContent(text: ""))],
            stopReason: .endTurn
        )
        var ended = false

        func text(from message: AssistantMessage) -> String {
            message.content.compactMap { block -> String? in
                if case .text(let textBlock) = block {
                    return textBlock.text
                }
                return nil
            }.joined()
        }

        func currentPartial() -> AssistantMessage {
            AssistantMessage(
                content: [.text(TextContent(text: text(from: partial)))],
                stopReason: .endTurn
            )
        }

        func endWithDone() {
            guard !ended else { return }
            ended = true
            let final = currentPartial()
            output.push(.textEnd(contentIndex: 0, content: text(from: final), partial: final))
            output.push(.done(reason: .endTurn, message: final))
            output.end(final)
        }

        func endWithError(reason: StopReason, message: String) {
            guard !ended else { return }
            ended = true
            let final = AssistantMessage(
                content: [.text(TextContent(text: text(from: partial)))],
                stopReason: reason,
                errorMessage: message
            )
            output.push(.error(reason: reason, error: final))
            output.end(final)
        }

        func endAbortedIfNeeded() -> Bool {
            let cancelled = options?.cancellation?.isCancelled == true || Task.isCancelled
            guard cancelled else { return false }
            endWithError(reason: .aborted, message: "Request was aborted")
            return true
        }

        output.push(.start(partial: partial))
        output.push(.textStart(contentIndex: 0, partial: partial))

        if endAbortedIfNeeded() {
            return
        }

        let apiKey = options?.apiKey ?? defaultAPIKey
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            endWithError(reason: .error, message: "Missing OpenAI-compatible API key")
            return
        }

        let requestBaseURL = model.baseUrl.isEmpty ? defaultBaseURL : model.baseUrl
        guard let url = Self.completionsURL(baseURL: requestBaseURL) else {
            endWithError(reason: .error, message: "Invalid base URL: \(requestBaseURL)")
            return
        }

        let requestBody = Self.RequestBody(
            model: model.id,
            stream: true,
            messages: Self.buildMessages(from: context)
        )

        guard let body = try? JSONEncoder().encode(requestBody) else {
            endWithError(reason: .error, message: "Failed to encode request body")
            return
        }

        do {
            let (response, byteStream) = try await httpClient.stream(
                url: url,
                method: "POST",
                headers: [
                    "content-type": "application/json",
                    "accept": "text/event-stream",
                    "authorization": "Bearer \(apiKey)",
                ],
                body: body
            )

            if endAbortedIfNeeded() {
                return
            }

            guard (200...299).contains(response.statusCode) else {
                var bytes: [UInt8] = []
                for try await byte in byteStream {
                    if endAbortedIfNeeded() {
                        return
                    }
                    bytes.append(byte)
                    if bytes.count >= 4_096 {
                        break
                    }
                }
                let bodyText = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if bodyText.isEmpty {
                    endWithError(reason: .error, message: "OpenAI Chat Completions HTTP \(response.statusCode)")
                } else {
                    endWithError(reason: .error, message: "OpenAI Chat Completions HTTP \(response.statusCode): \(bodyText)")
                }
                return
            }

            let parser = SSEParser()
            var lineBuffer: [UInt8] = []
            var rawBytes: [UInt8] = []
            var sawStructuredChunk = false

            for try await byte in byteStream {
                if endAbortedIfNeeded() {
                    return
                }
                lineBuffer.append(byte)
                if rawBytes.count < 1_000_000 {
                    rawBytes.append(byte)
                }
                if byte == 0x0A {
                    if let line = String(data: Data(lineBuffer), encoding: .utf8) {
                        parser.ingest(line)
                    }
                    lineBuffer.removeAll(keepingCapacity: true)

                    for message in parser.drain() {
                        if endAbortedIfNeeded() {
                            return
                        }

                        let eventType = Self.resolveEventType(message: message)
                        if eventType == "done" {
                            sawStructuredChunk = true
                            endWithDone()
                            return
                        }

                        if let errorMessage = Self.resolveErrorMessage(message: message) {
                            sawStructuredChunk = true
                            endWithError(reason: .error, message: errorMessage)
                            return
                        }

                        if let delta = Self.resolveDelta(message: message), !delta.isEmpty {
                            sawStructuredChunk = true
                            let merged = text(from: partial) + delta
                            partial = AssistantMessage(
                                content: [.text(TextContent(text: merged))],
                                stopReason: .endTurn
                            )
                            output.push(.textDelta(contentIndex: 0, delta: delta, partial: partial))
                        }

                        if Self.hasFinishReason(message: message) {
                            sawStructuredChunk = true
                            endWithDone()
                            return
                        }
                    }
                }
            }

            if !lineBuffer.isEmpty, let trailing = String(data: Data(lineBuffer), encoding: .utf8) {
                parser.ingest(trailing)
            }

            for message in parser.finish() {
                if endAbortedIfNeeded() {
                    return
                }

                let eventType = Self.resolveEventType(message: message)
                if eventType == "done" {
                    sawStructuredChunk = true
                    endWithDone()
                    return
                }

                if let errorMessage = Self.resolveErrorMessage(message: message) {
                    sawStructuredChunk = true
                    endWithError(reason: .error, message: errorMessage)
                    return
                }

                if let delta = Self.resolveDelta(message: message), !delta.isEmpty {
                    sawStructuredChunk = true
                    let merged = text(from: partial) + delta
                    partial = AssistantMessage(
                        content: [.text(TextContent(text: merged))],
                        stopReason: .endTurn
                    )
                    output.push(.textDelta(contentIndex: 0, delta: delta, partial: partial))
                }

                if Self.hasFinishReason(message: message) {
                    sawStructuredChunk = true
                    endWithDone()
                    return
                }
            }

            if !sawStructuredChunk {
                let rawText = String(decoding: rawBytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawText.isEmpty {
                    if let object = Self.parseObject(rawText) {
                        if
                            let errorObject = object["error"] as? [String: Any],
                            let errorMessage = errorObject["message"] as? String,
                            !errorMessage.isEmpty
                        {
                            endWithError(reason: .error, message: errorMessage)
                            return
                        }
                        if let errorMessage = object["error"] as? String, !errorMessage.isEmpty {
                            endWithError(reason: .error, message: errorMessage)
                            return
                        }
                        if let content = Self.resolveNonStreamingContent(object), !content.isEmpty {
                            partial = AssistantMessage(
                                content: [.text(TextContent(text: content))],
                                stopReason: .endTurn
                            )
                            output.push(.textDelta(contentIndex: 0, delta: content, partial: partial))
                            endWithDone()
                            return
                        }
                    }
                }
            }

            if endAbortedIfNeeded() {
                return
            }
            endWithDone()
        } catch {
            if endAbortedIfNeeded() {
                return
            }
            endWithError(reason: .error, message: "OpenAI Chat Completions stream failed: \(error)")
        }
    }

    private struct RequestBody: Encodable {
        let model: String
        let stream: Bool
        let messages: [InputMessage]
    }

    private struct InputMessage: Encodable {
        let role: String
        let content: String
    }

    private static func completionsURL(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: "\(base)/v1/chat/completions")
    }

    private static func buildMessages(from context: Context) -> [InputMessage] {
        var messages: [InputMessage] = []

        if let system = context.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            messages.append(InputMessage(role: "system", content: system))
        }

        for message in context.messages {
            switch message {
            case .user(let user):
                let text = user.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    messages.append(InputMessage(role: "user", content: text))
                }
            case .assistant(let assistant):
                let text = assistant.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text }
                    return nil
                }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    messages.append(InputMessage(role: "assistant", content: text))
                }
            case .tool(let toolResult):
                let prefix = toolResult.isError ? "[tool error]" : "[tool result]"
                messages.append(InputMessage(role: "user", content: "\(prefix) \(toolResult.toolCallId): \(toolResult.output)"))
            }
        }

        return messages
    }

    private static func resolveEventType(message: SSEMessage) -> String {
        let trimmed = message.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" {
            return "done"
        }
        return message.event
    }

    private static func resolveDelta(message: SSEMessage) -> String? {
        guard let object = parseObject(message.data) else { return nil }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            return nil
        }

        if let deltaObject = first["delta"] as? [String: Any] {
            if let content = deltaObject["content"] as? String {
                return content
            }
            if let reasoning = deltaObject["reasoning_content"] as? String {
                return reasoning
            }
            if
                let contentArray = deltaObject["content"] as? [[String: Any]],
                let firstContent = contentArray.first,
                let text = firstContent["text"] as? String
            {
                return text
            }
        }

        if
            let messageObject = first["message"] as? [String: Any],
            let content = messageObject["content"] as? String
        {
            return content
        }

        return nil
    }

    private static func resolveNonStreamingContent(_ object: [String: Any]) -> String? {
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            return nil
        }
        if
            let messageObject = first["message"] as? [String: Any],
            let content = messageObject["content"] as? String
        {
            return content
        }
        return nil
    }

    private static func hasFinishReason(message: SSEMessage) -> Bool {
        guard let object = parseObject(message.data) else { return false }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            return false
        }
        guard let finishReason = first["finish_reason"] as? String else {
            return false
        }
        return !finishReason.isEmpty
    }

    private static func resolveErrorMessage(message: SSEMessage) -> String? {
        guard let object = parseObject(message.data) else {
            return nil
        }

        if
            let errorObject = object["error"] as? [String: Any],
            let errorMessage = errorObject["message"] as? String,
            !errorMessage.isEmpty
        {
            return errorMessage
        }

        if let errorMessage = object["error"] as? String, !errorMessage.isEmpty {
            return errorMessage
        }

        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }

        return nil
    }

    private static func parseObject(_ data: String) -> [String: Any]? {
        guard let payload = data.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        return object as? [String: Any]
    }
}
