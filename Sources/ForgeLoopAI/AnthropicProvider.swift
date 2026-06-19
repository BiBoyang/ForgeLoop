import Foundation
import ForgeLoopDiagnostics

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

    public func stream(model: Model, context: Context, options: StreamOptions?) async -> AssistantMessageStream {
        let out = AssistantMessageStream()
        let worker = Task { [self] in
            let diagnostics = options?.diagnostics ?? Diagnostics()
            let span = await diagnostics.trace.startSpan(
                name: "provider.stream",
                parent: options?.traceContext,
                layer: "AI",
                operation: "stream",
                attributes: [
                    "provider": .string(api),
                    "model": .string(model.id)
                ]
            )
            await runStream(
                model: model,
                context: context,
                options: options,
                output: out,
                diagnostics: diagnostics,
                span: span
            )
        }
        options?.cancellation?.onCancel { _ in
            worker.cancel()
        }
        return out
    }

    // swiftlint:disable:next function_parameter_count
    private func runStream(
        model: Model,
        context: Context,
        options: StreamOptions?,
        output: AssistantMessageStream,
        diagnostics: Diagnostics,
        span: TraceContext
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
        var lastMessageUpdateLog: ContinuousClock.Instant?

        func finishSpan(_ error: TraceError?) async {
            await diagnostics.trace.endSpan(span, attributes: [:], error: error)
        }

        func logTextDelta() async {
            let now = ContinuousClock().now
            if let last = lastMessageUpdateLog, now.advanced(by: .seconds(-1)) < last {
                return
            }
            await diagnostics.log.log(
                level: .debug,
                message: "message.text.delta",
                attributes: ["provider": .string(api)]
            )
            lastMessageUpdateLog = now
        }

        /// Mutable box for propagating the first span error out of nested helper functions.
        /// `@unchecked Sendable` because it is only accessed serially within a single `runStream` task.
        final class SpanErrorBox: @unchecked Sendable {
            var error: TraceError?
        }
        let spanError = SpanErrorBox()

        func text(from message: AssistantMessage) -> String {
            message.content.compactMap { block -> String? in
                if case .text(let textBlock) = block { return textBlock.text }
                return nil
            }.joined()
        }

        func endWithDone(toolUse: Bool = false) async {
            guard !ended else { return }
            ended = true
            let reason: StopReason = toolUse || !pendingToolCalls.isEmpty ? .toolUse : .endTurn
            let final = buildFinalMessage(stopReason: reason)
            let textContent = text(from: final)
            if !textContent.isEmpty {
                output.push(.textEnd(contentIndex: 0, content: textContent, partial: final))
            }
            output.push(.done(reason: reason, message: final))
            await finishSpan(spanError.error)
            output.end(final)
        }

        func endWithError(reason: StopReason, message: String) async {
            guard !ended else { return }
            if spanError.error == nil {
                spanError.error = TraceError(type: "ProviderError", message: message)
            }
            ended = true
            let final = buildFinalMessage(stopReason: reason)
            let finalWithError = AssistantMessage(
                content: final.content,
                stopReason: reason,
                errorMessage: message
            )
            output.push(.error(reason: reason, error: finalWithError))
            await finishSpan(spanError.error)
            output.end(finalWithError)
        }

        func endAbortedIfNeeded() async -> Bool {
            let cancelled = options?.cancellation?.isCancelled == true || Task.isCancelled
            guard cancelled else { return false }
            spanError.error = TraceError(type: "Cancellation", message: "Request was aborted")
            await endWithError(reason: .aborted, message: "Request was aborted")
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

        if await endAbortedIfNeeded() {
            return
        }

        let apiKey = options?.apiKey ?? defaultAPIKey
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            spanError.error = TraceError(type: "ProviderError", message: "Missing Anthropic API key")
            await endWithError(reason: .error, message: "Missing Anthropic API key")
            return
        }

        let requestBaseURL = model.baseUrl.isEmpty ? defaultBaseURL : model.baseUrl
        guard let url = Self.messagesURL(baseURL: requestBaseURL) else {
            let message = "Invalid base URL: \(requestBaseURL)"
            spanError.error = TraceError(type: "ProviderError", message: message)
            await endWithError(reason: .error, message: message)
            return
        }

        guard let body = Self.buildRequestBody(model: model.id, context: context, options: options) else {
            spanError.error = TraceError(type: "ProviderError", message: "Failed to encode request body")
            await endWithError(reason: .error, message: "Failed to encode request body")
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
                    "anthropic-version": "2023-06-01"
                ],
                body: body,
                traceContext: span
            )

            if await endAbortedIfNeeded() {
                return
            }

            guard (200...299).contains(response.statusCode) else {
                var bytes: [UInt8] = []
                for try await byte in byteStream {
                    if await endAbortedIfNeeded() {
                        return
                    }
                    bytes.append(byte)
                    if bytes.count >= 4_096 {
                        break
                    }
                }
                let bodyText = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let errorMessage = bodyText.isEmpty
                    ? "Anthropic HTTP \(response.statusCode)"
                    : "Anthropic HTTP \(response.statusCode): \(bodyText)"
                spanError.error = TraceError(type: "HTTPError", message: errorMessage)
                await endWithError(reason: .error, message: errorMessage)
                return
            }

            var parser = SSEParser()
            var lineBuffer: [UInt8] = []
            var rawBytes: [UInt8] = []
            var sawStructuredChunk = false

            for try await byte in byteStream {
                if await endAbortedIfNeeded() {
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
                        if await endAbortedIfNeeded() {
                            return
                        }

                        if let errorMessage = Self.resolveErrorMessage(message: message) {
                            sawStructuredChunk = true
                            spanError.error = TraceError(type: "ProviderError", message: errorMessage)
                            await endWithError(reason: .error, message: errorMessage)
                            return
                        }

                        await diagnostics.log.log(
                            level: .debug,
                            message: "sse.parse.event",
                            attributes: ["event_type": .string(message.event)]
                        )
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
                                    await logTextDelta()
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
                            await endWithDone(toolUse: toolUse)
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
                if await endAbortedIfNeeded() {
                    return
                }

                if let errorMessage = Self.resolveErrorMessage(message: message) {
                    sawStructuredChunk = true
                    spanError.error = TraceError(type: "ProviderError", message: errorMessage)
                    await endWithError(reason: .error, message: errorMessage)
                    return
                }

                await diagnostics.log.log(
                    level: .debug,
                    message: "sse.parse.event",
                    attributes: ["event_type": .string(message.event)]
                )
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
                            await logTextDelta()
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
                    await endWithDone(toolUse: toolUse)
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
                            spanError.error = TraceError(type: "ProviderError", message: errorMessage)
                            await endWithError(reason: .error, message: errorMessage)
                            return
                        }
                        if let errorMessage = object["error"] as? String, !errorMessage.isEmpty {
                            spanError.error = TraceError(type: "ProviderError", message: errorMessage)
                            await endWithError(reason: .error, message: errorMessage)
                            return
                        }
                        if let content = Self.resolveNonStreamingContent(object), !content.isEmpty {
                            partial = AssistantMessage(
                                content: [.text(TextContent(text: content))],
                                stopReason: .endTurn
                            )
                            output.push(.textDelta(contentIndex: 0, delta: content, partial: partial))
                            await logTextDelta()
                            await endWithDone()
                            return
                        }
                    }
                }
            }

            if await endAbortedIfNeeded() {
                return
            }
            let toolUse = (stopReason == "tool_use" || !pendingToolCalls.isEmpty)
            await endWithDone(toolUse: toolUse)
        } catch {
            if await endAbortedIfNeeded() {
                return
            }
            let errorMessage = "Anthropic stream failed: \(error)"
            spanError.error = TraceError(type: "StreamError", message: errorMessage)
            await endWithError(reason: .error, message: errorMessage)
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
            "stream": true
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
