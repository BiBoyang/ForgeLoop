import Foundation

public final class OpenAIResponsesProvider: APIProvider, @unchecked Sendable {
    public let api: String

    private let defaultBaseURL: String
    private let defaultAPIKey: String?
    private let httpClient: any HTTPClient

    public init(
        api: String = "openai-responses",
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
            endWithError(reason: .error, message: "Missing OpenAI API key")
            return
        }

        let requestBaseURL = model.baseUrl.isEmpty ? defaultBaseURL : model.baseUrl
        guard let url = Self.responsesURL(baseURL: requestBaseURL) else {
            endWithError(reason: .error, message: "Invalid base URL: \(requestBaseURL)")
            return
        }

        let requestBody = Self.RequestBody(
            model: model.id,
            stream: true,
            input: Self.buildInput(from: context)
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
                    endWithError(reason: .error, message: "OpenAI Responses HTTP \(response.statusCode)")
                } else {
                    endWithError(reason: .error, message: "OpenAI Responses HTTP \(response.statusCode): \(bodyText)")
                }
                return
            }

            let parser = SSEParser()
            var lineBuffer: [UInt8] = []

            for try await byte in byteStream {
                if endAbortedIfNeeded() {
                    return
                }
                lineBuffer.append(byte)
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
                        switch eventType {
                        case "response.output_text.delta":
                            guard let delta = Self.resolveDelta(message: message), !delta.isEmpty else { continue }
                            let merged = text(from: partial) + delta
                            partial = AssistantMessage(
                                content: [.text(TextContent(text: merged))],
                                stopReason: .endTurn
                            )
                            output.push(.textDelta(contentIndex: 0, delta: delta, partial: partial))
                        case "response.completed":
                            endWithDone()
                            return
                        case "response.failed", "response.error":
                            endWithError(reason: .error, message: Self.resolveErrorMessage(message: message))
                            return
                        default:
                            continue
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
                switch eventType {
                case "response.output_text.delta":
                    guard let delta = Self.resolveDelta(message: message), !delta.isEmpty else { continue }
                    let merged = text(from: partial) + delta
                    partial = AssistantMessage(
                        content: [.text(TextContent(text: merged))],
                        stopReason: .endTurn
                    )
                    output.push(.textDelta(contentIndex: 0, delta: delta, partial: partial))
                case "response.completed":
                    endWithDone()
                    return
                case "response.failed", "response.error":
                    endWithError(reason: .error, message: Self.resolveErrorMessage(message: message))
                    return
                default:
                    continue
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
            endWithError(reason: .error, message: "OpenAI Responses stream failed: \(error)")
        }
    }

    private struct RequestBody: Encodable {
        let model: String
        let stream: Bool
        let input: [InputItem]
    }

    private struct InputItem: Encodable {
        let role: String
        let content: String
    }

    private static func responsesURL(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: "\(base)/v1/responses")
    }

    private static func buildInput(from context: Context) -> [InputItem] {
        var input: [InputItem] = []

        if let system = context.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            input.append(InputItem(role: "system", content: system))
        }

        for message in context.messages {
            switch message {
            case .user(let user):
                let text = user.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    input.append(InputItem(role: "user", content: text))
                }
            case .assistant(let assistant):
                let text = assistant.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text }
                    return nil
                }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    input.append(InputItem(role: "assistant", content: text))
                }
            case .tool(let toolResult):
                // 将 tool_result 作为 user 消息注入，供后续 Responses API 使用
                let prefix = toolResult.isError ? "[tool error]" : "[tool result]"
                input.append(InputItem(role: "user", content: "\(prefix) \(toolResult.toolCallId): \(toolResult.output)"))
            }
        }

        return input
    }

    private static func resolveEventType(message: SSEMessage) -> String {
        let trimmed = message.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" {
            return "response.completed"
        }

        if let object = parseObject(message.data), let type = object["type"] as? String, !type.isEmpty {
            return type
        }
        return message.event
    }

    private static func resolveDelta(message: SSEMessage) -> String? {
        guard let object = parseObject(message.data) else { return nil }
        if let delta = object["delta"] as? String {
            return delta
        }
        if let text = object["text"] as? String {
            return text
        }
        return nil
    }

    private static func resolveErrorMessage(message: SSEMessage) -> String {
        if let object = parseObject(message.data) {
            if let error = object["error"] as? String, !error.isEmpty {
                return error
            }
            if
                let errorObject = object["error"] as? [String: Any],
                let errorMessage = errorObject["message"] as? String,
                !errorMessage.isEmpty
            {
                return errorMessage
            }
            if let errorMessage = object["message"] as? String, !errorMessage.isEmpty {
                return errorMessage
            }
        }

        let raw = message.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            return raw
        }
        return "OpenAI Responses returned an error event"
    }

    private static func parseObject(_ data: String) -> [String: Any]? {
        guard let payload = data.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        return object as? [String: Any]
    }
}
