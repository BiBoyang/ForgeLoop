import Foundation
import ForgeLoopDiagnostics

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
        var partial = AssistantMessage(
            content: [.text(TextContent(text: ""))],
            stopReason: .endTurn
        )
        var ended = false
        var pendingToolCalls: [Int: PendingToolCall] = [:]
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
                if case .text(let textBlock) = block {
                    return textBlock.text
                }
                return nil
            }.joined()
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
                if let name = pending.name {
                    let id = pending.id ?? "call_\(index)"
                    content.append(.toolCall(ToolCall(
                        id: id,
                        name: name,
                        arguments: pending.arguments
                    )))
                }
            }
            return AssistantMessage(
                content: content,
                stopReason: stopReason
            )
        }

        func endWithDone(toolUse: Bool = false) async {
            guard !ended else { return }
            ended = true
            let stopReason: StopReason = toolUse ? .toolUse : .endTurn
            let final = buildFinalMessage(stopReason: stopReason)
            let textContent = text(from: partial)
            if !textContent.isEmpty {
                output.push(.textEnd(contentIndex: 0, content: textContent, partial: final))
            }
            output.push(.done(reason: stopReason, message: final))
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

        output.push(.start(partial: partial))
        output.push(.textStart(contentIndex: 0, partial: partial))

        if await endAbortedIfNeeded() {
            return
        }

        let apiKey = options?.apiKey ?? defaultAPIKey
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            spanError.error = TraceError(type: "ProviderError", message: "Missing OpenAI-compatible API key")
            await endWithError(reason: .error, message: "Missing OpenAI-compatible API key")
            return
        }

        let requestBaseURL = model.baseUrl.isEmpty ? defaultBaseURL : model.baseUrl
        guard let url = Self.completionsURL(baseURL: requestBaseURL) else {
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
                    "authorization": "Bearer \(apiKey)"
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
                    ? "OpenAI Chat Completions HTTP \(response.statusCode)"
                    : "OpenAI Chat Completions HTTP \(response.statusCode): \(bodyText)"
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

                        let eventType = Self.resolveEventType(message: message)
                        await diagnostics.log.log(
                            level: .debug,
                            message: "sse.parse.event",
                            attributes: ["event_type": .string(eventType)]
                        )
                        if eventType == "done" {
                            sawStructuredChunk = true
                            await endWithDone(toolUse: !pendingToolCalls.isEmpty)
                            return
                        }

                        if let errorMessage = Self.resolveErrorMessage(message: message) {
                            sawStructuredChunk = true
                            spanError.error = TraceError(type: "ProviderError", message: errorMessage)
                            await endWithError(reason: .error, message: errorMessage)
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
                            await logTextDelta()
                        }

                        if let toolDeltas = Self.resolveToolCallsDelta(message: message) {
                            sawStructuredChunk = true
                            for (index, delta) in toolDeltas {
                                var pending = pendingToolCalls[index] ?? PendingToolCall()
                                if let id = delta.id { pending.id = id }
                                if let name = delta.name { pending.name = name }
                                if let args = delta.arguments { pending.arguments += args }
                                pendingToolCalls[index] = pending
                            }
                        }

                        if let finishReason = Self.resolveFinishReason(message: message), !finishReason.isEmpty {
                            sawStructuredChunk = true
                            let toolUse = (finishReason == "tool_calls" || finishReason == "function_call")
                            await endWithDone(toolUse: toolUse)
                            return
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

                let eventType = Self.resolveEventType(message: message)
                await diagnostics.log.log(
                    level: .debug,
                    message: "sse.parse.event",
                    attributes: ["event_type": .string(eventType)]
                )
                if eventType == "done" {
                    sawStructuredChunk = true
                    await endWithDone(toolUse: !pendingToolCalls.isEmpty)
                    return
                }

                if let errorMessage = Self.resolveErrorMessage(message: message) {
                    sawStructuredChunk = true
                    spanError.error = TraceError(type: "ProviderError", message: errorMessage)
                    await endWithError(reason: .error, message: errorMessage)
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
                    await logTextDelta()
                }

                if let toolDeltas = Self.resolveToolCallsDelta(message: message) {
                    sawStructuredChunk = true
                    for (index, delta) in toolDeltas {
                        var pending = pendingToolCalls[index] ?? PendingToolCall()
                        if let id = delta.id { pending.id = id }
                        if let name = delta.name { pending.name = name }
                        if let args = delta.arguments { pending.arguments += args }
                        pendingToolCalls[index] = pending
                    }
                }

                if let finishReason = Self.resolveFinishReason(message: message), !finishReason.isEmpty {
                    sawStructuredChunk = true
                    let toolUse = (finishReason == "tool_calls" || finishReason == "function_call")
                    await endWithDone(toolUse: toolUse)
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
            await endWithDone()
        } catch {
            if await endAbortedIfNeeded() {
                return
            }
            let errorMessage = "OpenAI Chat Completions stream failed: \(error)"
            spanError.error = TraceError(type: "StreamError", message: errorMessage)
            await endWithError(reason: .error, message: errorMessage)
        }
    }

    private static func completionsURL(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: "\(base)/v1/chat/completions")
    }

    private static func buildRequestBody(model: String, context: Context, options: StreamOptions?) -> Data? {
        var body: [String: Any] = [
            "model": model,
            "stream": true
        ]

        // Messages
        var messages: [[String: Any]] = []
        if let system = context.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }

        for message in context.messages {
            switch message {
            case .user(let user):
                let text = user.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    messages.append(["role": "user", "content": text])
                }
            case .assistant(let assistant):
                let textBlocks = assistant.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text }
                    return nil
                }
                let toolCallBlocks = assistant.content.compactMap { block -> [String: Any]? in
                    if case .toolCall(let tc) = block {
                        return [
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": tc.name,
                                "arguments": tc.arguments
                            ]
                        ]
                    }
                    return nil
                }
                var assistantMessage: [String: Any] = ["role": "assistant"]
                let text = textBlocks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    assistantMessage["content"] = text
                } else {
                    assistantMessage["content"] = NSNull()
                }
                if !toolCallBlocks.isEmpty {
                    assistantMessage["tool_calls"] = toolCallBlocks
                }
                messages.append(assistantMessage)
            case .tool(let toolResult):
                messages.append([
                    "role": "tool",
                    "tool_call_id": toolResult.toolCallId,
                    "content": toolResult.output
                ])
            }
        }
        body["messages"] = messages

        // Tools
        if let tools = options?.tools, !tools.isEmpty {
            let toolsArray: [[String: Any]] = tools.map { tool in
                var function: [String: Any] = ["name": tool.name]
                if !tool.description.isEmpty {
                    function["description"] = tool.description
                }
                if let params = try? JSONSerialization.jsonObject(with: tool.parametersJSON) {
                    function["parameters"] = params
                }
                return ["type": "function", "function": function]
            }
            body["tools"] = toolsArray
        }

        if let toolChoice = options?.toolChoice, !toolChoice.isEmpty {
            body["tool_choice"] = toolChoice
        }

        return try? JSONSerialization.data(withJSONObject: body)
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
                let text = firstContent["text"] as? String {
                return text
            }
        }

        if
            let messageObject = first["message"] as? [String: Any],
            let content = messageObject["content"] as? String {
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
            let content = messageObject["content"] as? String {
            return content
        }
        return nil
    }

    private static func resolveErrorMessage(message: SSEMessage) -> String? {
        guard let object = parseObject(message.data) else {
            return nil
        }

        if
            let errorObject = object["error"] as? [String: Any],
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

    private static func parseObject(_ data: String) -> [String: Any]? {
        guard let payload = data.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        return object as? [String: Any]
    }
}

// MARK: - Tool Call Parsing

private struct PendingToolCall: Sendable {
    var id: String?
    var name: String?
    var arguments: String = ""
}

private struct ToolCallDelta: Sendable {
    let id: String?
    let name: String?
    let arguments: String?
}

extension OpenAIChatCompletionsProvider {
    fileprivate static func resolveToolCallsDelta(message: SSEMessage) -> [Int: ToolCallDelta]? {
        guard let object = parseObject(message.data) else { return nil }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            return nil
        }
        guard let delta = first["delta"] as? [String: Any] else { return nil }

        // Primary path: tool_calls
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            var result: [Int: ToolCallDelta] = [:]
            for item in toolCalls {
                guard let index = item["index"] as? Int else { continue }
                let id = item["id"] as? String
                var name: String?
                var arguments: String?
                if let function = item["function"] as? [String: Any] {
                    name = function["name"] as? String
                    arguments = function["arguments"] as? String
                }
                result[index] = ToolCallDelta(id: id, name: name, arguments: arguments)
            }
            return result.isEmpty ? nil : result
        }

        // Legacy path: function_call
        if let functionCall = delta["function_call"] as? [String: Any] {
            let name = functionCall["name"] as? String
            let arguments = functionCall["arguments"] as? String
            return [0: ToolCallDelta(id: nil, name: name, arguments: arguments)]
        }

        return nil
    }

    fileprivate static func resolveFinishReason(message: SSEMessage) -> String? {
        guard let object = parseObject(message.data) else { return nil }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            return nil
        }
        return first["finish_reason"] as? String
    }
}
