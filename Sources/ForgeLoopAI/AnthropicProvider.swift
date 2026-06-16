import Foundation

public final class AnthropicProvider: APIProvider, @unchecked Sendable {
    public let api: String = "anthropic"

    private let defaultBaseURL: String
    private let defaultAPIKey: String?
    private let httpClient: any HTTPClient

    public init(
        baseURL: String = "https://api.anthropic.com",
        defaultAPIKey: String? = nil,
        httpClient: any HTTPClient = URLSessionHTTPClient()
    ) {
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
        var ended = false
        var partial = AssistantMessage(
            content: [.text(TextContent(text: ""))],
            stopReason: .endTurn
        )
        var currentContentIndex: Int?
        var currentToolCall: PendingAnthropicToolCall?
        var pendingToolCalls: [Int: PendingAnthropicToolCall] = [:]
        var stopReason: String?

        func text(from message: AssistantMessage) -> String {
            message.content.compactMap { block -> String? in
                if case .text(let textBlock) = block { return textBlock.text }
                return nil
            }.joined()
        }

        func endWithDone(toolUse: Bool = false) {
            guard !ended else { return }
            ended = true
            let reason: StopReason = toolUse || !pendingToolCalls.isEmpty ? .toolUse : .endTurn
            let final = buildFinalMessage(stopReason: reason)
            let textContent = text(from: final)
            if !textContent.isEmpty {
                output.push(.textEnd(contentIndex: 0, content: textContent, partial: final))
            }
            output.push(.done(reason: reason, message: final))
            output.end(final)
        }

        func endWithError(reason: StopReason, message: String) {
            guard !ended else { return }
            ended = true
            let final = buildFinalMessage(stopReason: reason)
            let finalWithError = AssistantMessage(
                content: final.content,
                stopReason: reason,
                errorMessage: message
            )
            output.push(.error(reason: reason, error: finalWithError))
            output.end(finalWithError)
        }

        func endAbortedIfNeeded() -> Bool {
            let cancelled = options?.cancellation?.isCancelled == true || Task.isCancelled
            guard cancelled else { return false }
            endWithError(reason: .aborted, message: "Request was aborted")
            return true
        }

        func buildFinalMessage(stopReason: StopReason) -> AssistantMessage {
            var content: [AssistantBlock] = []
            let textContent = text(from: partial)
            if !textContent.isEmpty {
                content.append(.text(TextContent(text: textContent)))
            }
            let sortedIndices = pendingToolCalls.keys.sorted()
            for index in sortedIndices {
                let pending = pendingToolCalls[index]!
                if let name = pending.name, let id = pending.id {
                    content.append(.toolCall(ToolCall(
                        id: id,
                        name: name,
                        arguments: pending.arguments
                    )))
                }
            }
            return AssistantMessage(content: content, stopReason: stopReason)
        }

        output.push(.start(partial: partial))
        output.push(.textStart(contentIndex: 0, partial: partial))

        if endAbortedIfNeeded() {
            return
        }

        let apiKey = options?.apiKey ?? defaultAPIKey
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            endWithError(reason: .error, message: "Missing Anthropic API key")
            return
        }

        let requestBaseURL = model.baseUrl.isEmpty ? defaultBaseURL : model.baseUrl
        guard let url = Self.messagesURL(baseURL: requestBaseURL) else {
            endWithError(reason: .error, message: "Invalid base URL: \(requestBaseURL)")
            return
        }

        guard let body = Self.buildRequestBody(model: model.id, context: context, options: options) else {
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
                    "x-api-key": apiKey,
                    "anthropic-version": "2023-06-01",
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
                    endWithError(reason: .error, message: "Anthropic HTTP \(response.statusCode)")
                } else {
                    endWithError(reason: .error, message: "Anthropic HTTP \(response.statusCode): \(bodyText)")
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

                        if let errorMessage = Self.resolveErrorMessage(message: message) {
                            sawStructuredChunk = true
                            endWithError(reason: .error, message: errorMessage)
                            return
                        }

                        switch message.event {
                        case "content_block_start":
                            sawStructuredChunk = true
                            if let block = Self.resolveContentBlockStart(message: message) {
                                currentContentIndex = block.index
                                switch block.type {
                                case .text:
                                    break
                                case .toolUse(let id, let name):
                                    currentToolCall = PendingAnthropicToolCall(id: id, name: name)
                                }
                            }

                        case "content_block_delta":
                            sawStructuredChunk = true
                            if let delta = Self.resolveContentBlockDelta(message: message) {
                                switch delta {
                                case .text(let deltaText):
                                    let merged = text(from: partial) + deltaText
                                    partial = AssistantMessage(
                                        content: [.text(TextContent(text: merged))],
                                        stopReason: .endTurn
                                    )
                                    output.push(.textDelta(contentIndex: currentContentIndex ?? 0, delta: deltaText, partial: partial))
                                case .inputJson(let json):
                                    if currentToolCall != nil {
                                        currentToolCall!.arguments += json
                                    }
                                }
                            }

                        case "content_block_stop":
                            sawStructuredChunk = true
                            if let index = Self.resolveContentBlockStopIndex(message: message) {
                                if let toolCall = currentToolCall {
                                    pendingToolCalls[index] = toolCall
                                    currentToolCall = nil
                                } else {
                                    let textContent = text(from: partial)
                                    if !textContent.isEmpty {
                                        output.push(.textEnd(contentIndex: index, content: textContent, partial: partial))
                                    }
                                }
                            }
                            currentContentIndex = nil

                        case "message_delta":
                            sawStructuredChunk = true
                            if let reason = Self.resolveStopReason(message: message) {
                                stopReason = reason
                            }

                        case "message_stop":
                            sawStructuredChunk = true
                            let toolUse = (stopReason == "tool_use" || !pendingToolCalls.isEmpty)
                            endWithDone(toolUse: toolUse)
                            return

                        default:
                            break
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

                if let errorMessage = Self.resolveErrorMessage(message: message) {
                    sawStructuredChunk = true
                    endWithError(reason: .error, message: errorMessage)
                    return
                }

                switch message.event {
                case "content_block_start":
                    sawStructuredChunk = true
                    if let block = Self.resolveContentBlockStart(message: message) {
                        currentContentIndex = block.index
                        switch block.type {
                        case .text:
                            break
                        case .toolUse(let id, let name):
                            currentToolCall = PendingAnthropicToolCall(id: id, name: name)
                        }
                    }

                case "content_block_delta":
                    sawStructuredChunk = true
                    if let delta = Self.resolveContentBlockDelta(message: message) {
                        switch delta {
                        case .text(let deltaText):
                            let merged = text(from: partial) + deltaText
                            partial = AssistantMessage(
                                content: [.text(TextContent(text: merged))],
                                stopReason: .endTurn
                            )
                            output.push(.textDelta(contentIndex: currentContentIndex ?? 0, delta: deltaText, partial: partial))
                        case .inputJson(let json):
                            if currentToolCall != nil {
                                currentToolCall!.arguments += json
                            }
                        }
                    }

                case "content_block_stop":
                    sawStructuredChunk = true
                    if let index = Self.resolveContentBlockStopIndex(message: message) {
                        if let toolCall = currentToolCall {
                            pendingToolCalls[index] = toolCall
                            currentToolCall = nil
                        } else {
                            let textContent = text(from: partial)
                            if !textContent.isEmpty {
                                output.push(.textEnd(contentIndex: index, content: textContent, partial: partial))
                            }
                        }
                    }
                    currentContentIndex = nil

                case "message_delta":
                    sawStructuredChunk = true
                    if let reason = Self.resolveStopReason(message: message) {
                        stopReason = reason
                    }

                case "message_stop":
                    sawStructuredChunk = true
                    let toolUse = (stopReason == "tool_use" || !pendingToolCalls.isEmpty)
                    endWithDone(toolUse: toolUse)
                    return

                default:
                    break
                }
            }

            if !sawStructuredChunk {
                let rawText = String(decoding: rawBytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawText.isEmpty {
                    if let object = Self.parseObject(rawText) {
                        if let errorObject = object["error"] as? [String: Any],
                           let errorMessage = errorObject["message"] as? String,
                           !errorMessage.isEmpty {
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
            let toolUse = (stopReason == "tool_use" || !pendingToolCalls.isEmpty)
            endWithDone(toolUse: toolUse)
        } catch {
            if endAbortedIfNeeded() {
                return
            }
            endWithError(reason: .error, message: "Anthropic stream failed: \(error)")
        }
    }

    // MARK: - Request Building

    private static func messagesURL(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: "\(base)/v1/messages")
    }

    private static func buildRequestBody(model: String, context: Context, options: StreamOptions?) -> Data? {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
        ]

        if let system = context.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            body["system"] = system
        }

        body["messages"] = convertMessagesToAnthropicFormat(context.messages)

        if let tools = options?.tools, !tools.isEmpty {
            let toolsArray: [[String: Any]] = tools.map { tool in
                var toolDict: [String: Any] = ["name": tool.name]
                if !tool.description.isEmpty {
                    toolDict["description"] = tool.description
                }
                if let params = try? JSONSerialization.jsonObject(with: tool.parametersJSON) {
                    toolDict["input_schema"] = params
                }
                return toolDict
            }
            body["tools"] = toolsArray
        }

        if let toolChoice = options?.toolChoice, !toolChoice.isEmpty {
            body["tool_choice"] = ["type": toolChoice]
        }

        return try? JSONSerialization.data(withJSONObject: body)
    }

    private static func convertMessagesToAnthropicFormat(_ messages: [Message]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages {
            switch message {
            case .user(let user):
                let text = user.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result.append([
                        "role": "user",
                        "content": [["type": "text", "text": text]]
                    ])
                }
            case .assistant(let assistant):
                var content: [[String: Any]] = []
                for block in assistant.content {
                    switch block {
                    case .text(let textContent):
                        if !textContent.text.isEmpty {
                            content.append(["type": "text", "text": textContent.text])
                        }
                    case .toolCall(let toolCall):
                        let input: Any
                        if let parsed = try? JSONSerialization.jsonObject(with: toolCall.arguments.data(using: .utf8) ?? Data()) {
                            input = parsed
                        } else {
                            input = toolCall.arguments
                        }
                        content.append([
                            "type": "tool_use",
                            "id": toolCall.id,
                            "name": toolCall.name,
                            "input": input
                        ])
                    }
                }
                if !content.isEmpty {
                    result.append(["role": "assistant", "content": content])
                }
            case .tool(let toolResult):
                result.append([
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": toolResult.toolCallId,
                        "content": toolResult.output
                    ]]
                ])
            }
        }
        return result
    }

    // MARK: - SSE Response Parsing

    private static func parseObject(_ data: String) -> [String: Any]? {
        guard let payload = data.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        return object as? [String: Any]
    }

    private static func resolveErrorMessage(message: SSEMessage) -> String? {
        guard let object = parseObject(message.data) else { return nil }

        if let errorObject = object["error"] as? [String: Any],
           let errorMessage = errorObject["message"] as? String,
           !errorMessage.isEmpty {
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

    private static func resolveNonStreamingContent(_ object: [String: Any]) -> String? {
        guard let contentArray = object["content"] as? [[String: Any]] else { return nil }
        return contentArray.compactMap { item -> String? in
            guard (item["type"] as? String) == "text" else { return nil }
            return item["text"] as? String
        }.joined()
    }

    private enum ContentBlockType {
        case text
        case toolUse(id: String, name: String)
    }

    private struct ContentBlockStart {
        let index: Int
        let type: ContentBlockType
    }

    private enum ContentBlockDelta {
        case text(String)
        case inputJson(String)
    }

    private static func resolveContentBlockStart(message: SSEMessage) -> ContentBlockStart? {
        guard let object = parseObject(message.data) else { return nil }
        guard let index = object["index"] as? Int else { return nil }
        guard let contentBlock = object["content_block"] as? [String: Any] else { return nil }
        let type = contentBlock["type"] as? String
        switch type {
        case "text":
            return ContentBlockStart(index: index, type: .text)
        case "tool_use":
            let id = contentBlock["id"] as? String ?? ""
            let name = contentBlock["name"] as? String ?? ""
            return ContentBlockStart(index: index, type: .toolUse(id: id, name: name))
        default:
            return nil
        }
    }

    private static func resolveContentBlockDelta(message: SSEMessage) -> ContentBlockDelta? {
        guard let object = parseObject(message.data) else { return nil }
        guard let delta = object["delta"] as? [String: Any] else { return nil }
        let type = delta["type"] as? String
        switch type {
        case "text_delta":
            if let text = delta["text"] as? String {
                return .text(text)
            }
        case "input_json_delta":
            if let partialJson = delta["partial_json"] as? String {
                return .inputJson(partialJson)
            }
        default:
            break
        }
        return nil
    }

    private static func resolveContentBlockStopIndex(message: SSEMessage) -> Int? {
        guard let object = parseObject(message.data) else { return nil }
        return object["index"] as? Int
    }

    private static func resolveStopReason(message: SSEMessage) -> String? {
        guard let object = parseObject(message.data) else { return nil }
        guard let delta = object["delta"] as? [String: Any] else { return nil }
        return delta["stop_reason"] as? String
    }
}

private struct PendingAnthropicToolCall: Sendable {
    var id: String?
    var name: String?
    var arguments: String = ""
}
