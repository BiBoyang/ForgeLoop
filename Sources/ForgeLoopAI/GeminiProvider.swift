import Foundation

public final class GeminiProvider: APIProvider, @unchecked Sendable {
    public let api: String = "gemini"

    private let defaultBaseURL: String
    private let defaultAPIKey: String?
    private let httpClient: any HTTPClient

    public init(
        baseURL: String = "https://generativelanguage.googleapis.com",
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
        var partialText = ""
        var pendingToolCalls: [String: GeminiPendingToolCall] = [:]
        var callOrder: [String] = []
        var finalStopReason: String?

        func endWithDone(toolUse: Bool = false) {
            guard !ended else { return }
            ended = true
            let reason: StopReason = toolUse || !pendingToolCalls.isEmpty ? .toolUse : .endTurn
            let final = buildFinalMessage(stopReason: reason)
            if !partialText.isEmpty {
                output.push(.textEnd(contentIndex: 0, content: partialText, partial: final))
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
            if !partialText.isEmpty {
                content.append(.text(TextContent(text: partialText)))
            }
            for callId in callOrder {
                guard let pending = pendingToolCalls[callId] else { continue }
                if let name = pending.name {
                    content.append(.toolCall(ToolCall(
                        id: pending.id ?? callId,
                        name: name,
                        arguments: pending.arguments
                    )))
                }
            }
            return AssistantMessage(content: content, stopReason: stopReason)
        }

        let partial = AssistantMessage(
            content: [.text(TextContent(text: ""))],
            stopReason: .endTurn
        )
        output.push(.start(partial: partial))
        output.push(.textStart(contentIndex: 0, partial: partial))

        if endAbortedIfNeeded() {
            return
        }

        let apiKey = options?.apiKey ?? defaultAPIKey
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            endWithError(reason: .error, message: "Missing Gemini API key")
            return
        }

        let requestBaseURL = model.baseUrl.isEmpty ? defaultBaseURL : model.baseUrl
        guard let url = Self.streamURL(baseURL: requestBaseURL, model: model.id) else {
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
                    "x-goog-api-key": apiKey,
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
                    endWithError(reason: .error, message: "Gemini HTTP \(response.statusCode)")
                } else {
                    endWithError(reason: .error, message: "Gemini HTTP \(response.statusCode): \(bodyText)")
                }
                return
            }

            let parser = SSEParser()
            var lineBuffer: [UInt8] = []
            var sawStructuredChunk = false

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

                        if let errorMessage = Self.resolveErrorMessage(message: message) {
                            sawStructuredChunk = true
                            endWithError(reason: .error, message: errorMessage)
                            return
                        }

                        let candidate = Self.resolveCandidate(message: message)
                        if let candidate = candidate {
                            sawStructuredChunk = true

                            if let reason = candidate.finishReason, !reason.isEmpty {
                                finalStopReason = reason
                            }

                            for part in candidate.parts {
                                switch part {
                                case .text(let text):
                                    let delta = Self.deltaText(previous: partialText, current: text)
                                    partialText = text
                                    if !delta.isEmpty {
                                        let partial = AssistantMessage(
                                            content: [.text(TextContent(text: partialText))],
                                            stopReason: .endTurn
                                        )
                                        output.push(.textDelta(contentIndex: 0, delta: delta, partial: partial))
                                    }
                                case .functionCall(let callId, let name, let args):
                                    if var pending = pendingToolCalls[callId] {
                                        pending.name = pending.name ?? name
                                        pending.arguments += args
                                        pendingToolCalls[callId] = pending
                                    } else {
                                        callOrder.append(callId)
                                        pendingToolCalls[callId] = GeminiPendingToolCall(
                                            id: callId,
                                            name: name,
                                            arguments: args
                                        )
                                    }
                                }
                            }

                            let shouldEnd = candidate.finishReason == "STOP" || candidate.finishReason == "TOOL_CALLS"
                            if shouldEnd {
                                let toolUse = candidate.finishReason == "TOOL_CALLS" || !pendingToolCalls.isEmpty
                                endWithDone(toolUse: toolUse)
                                return
                            }
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

                if let candidate = Self.resolveCandidate(message: message) {
                    sawStructuredChunk = true

                    if let reason = candidate.finishReason, !reason.isEmpty {
                        finalStopReason = reason
                    }

                    for part in candidate.parts {
                        switch part {
                        case .text(let text):
                            let delta = Self.deltaText(previous: partialText, current: text)
                            partialText = text
                            if !delta.isEmpty {
                                let partial = AssistantMessage(
                                    content: [.text(TextContent(text: partialText))],
                                    stopReason: .endTurn
                                )
                                output.push(.textDelta(contentIndex: 0, delta: delta, partial: partial))
                            }
                        case .functionCall(let callId, let name, let args):
                            if var pending = pendingToolCalls[callId] {
                                pending.name = pending.name ?? name
                                pending.arguments += args
                                pendingToolCalls[callId] = pending
                            } else {
                                callOrder.append(callId)
                                pendingToolCalls[callId] = GeminiPendingToolCall(
                                    id: callId,
                                    name: name,
                                    arguments: args
                                )
                            }
                        }
                    }

                    let shouldEnd = candidate.finishReason == "STOP" || candidate.finishReason == "TOOL_CALLS"
                    if shouldEnd {
                        let toolUse = candidate.finishReason == "TOOL_CALLS" || !pendingToolCalls.isEmpty
                        endWithDone(toolUse: toolUse)
                        return
                    }
                }
            }

            if endAbortedIfNeeded() {
                return
            }

            if !sawStructuredChunk {
                endWithError(reason: .error, message: "Gemini returned an empty or unparseable stream")
                return
            }

            let toolUse = finalStopReason == "TOOL_CALLS" || !pendingToolCalls.isEmpty
            endWithDone(toolUse: toolUse)
        } catch let caughtError {
            if caughtError is CancellationError || options?.cancellation?.isCancelled == true || Task.isCancelled {
                if !ended {
                    endWithError(reason: .aborted, message: "Request was aborted")
                }
                return
            }
            endWithError(reason: .error, message: "Gemini stream failed: \(caughtError)")
        }
    }

    // MARK: - Request Building

    private static func streamURL(baseURL: String, model: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        let escapedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        return URL(string: "\(base)/v1beta/models/\(escapedModel):streamGenerateContent?alt=sse")
    }

    private static func buildRequestBody(model: String, context: Context, options: StreamOptions?) -> Data? {
        var body: [String: Any] = [:]

        var contents: [[String: Any]] = []
        for message in context.messages {
            switch message {
            case .user(let user):
                contents.append([
                    "role": "user",
                    "parts": [["text": user.text]]
                ])
            case .assistant(let assistant):
                var parts: [[String: Any]] = []
                for block in assistant.content {
                    switch block {
                    case .text(let textContent):
                        parts.append(["text": textContent.text])
                    case .toolCall(let toolCall):
                        let args: Any
                        if let parsed = try? JSONSerialization.jsonObject(with: toolCall.arguments.data(using: .utf8) ?? Data()) {
                            args = parsed
                        } else {
                            args = toolCall.arguments
                        }
                        parts.append([
                            "functionCall": [
                                "name": toolCall.name,
                                "args": args
                            ]
                        ])
                    }
                }
                if !parts.isEmpty {
                    contents.append(["role": "model", "parts": parts])
                }
            case .tool(let toolResult):
                let responseKey = toolResult.isError ? "error" : "content"
                contents.append([
                    "role": "user",
                    "parts": [[
                        "functionResponse": [
                            "name": toolResult.toolCallId,
                            "response": [responseKey: toolResult.output]
                        ]
                    ]]
                ])
            }
        }
        body["contents"] = contents

        if let system = context.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }

        if let tools = options?.tools, !tools.isEmpty {
            let declarations: [[String: Any]] = tools.map { tool in
                var declaration: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description
                ]
                if let params = try? JSONSerialization.jsonObject(with: tool.parametersJSON) {
                    declaration["parameters"] = params
                }
                return declaration
            }
            body["tools"] = [["functionDeclarations": declarations]]
        }

        body["generationConfig"] = ["maxOutputTokens": 8192]

        return try? JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Response Parsing

    private struct GeminiCandidate: Sendable {
        let finishReason: String?
        let parts: [GeminiPart]
    }

    private enum GeminiPart: Sendable {
        case text(String)
        case functionCall(id: String, name: String, arguments: String)
    }

    private static func resolveCandidate(message: SSEMessage) -> GeminiCandidate? {
        guard let object = parseObject(message.data) else { return nil }
        guard let candidates = object["candidates"] as? [[String: Any]], let candidate = candidates.first else {
            return nil
        }
        let finishReason = candidate["finishReason"] as? String
        guard let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return GeminiCandidate(finishReason: finishReason, parts: [])
        }

        var parsedParts: [GeminiPart] = []
        for (index, part) in parts.enumerated() {
            if let text = part["text"] as? String {
                parsedParts.append(.text(text))
            } else if let functionCall = part["functionCall"] as? [String: Any],
                      let name = functionCall["name"] as? String {
                let callId = functionCall["id"] as? String ?? "gemini-call-\(index)"
                let args: String
                if let argsObject = functionCall["args"] {
                    if let data = try? JSONSerialization.data(withJSONObject: argsObject),
                       let string = String(data: data, encoding: .utf8) {
                        args = string
                    } else {
                        args = "{}"
                    }
                } else {
                    args = "{}"
                }
                parsedParts.append(.functionCall(id: callId, name: name, arguments: args))
            }
        }
        return GeminiCandidate(finishReason: finishReason, parts: parsedParts)
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

    private static func parseObject(_ data: String) -> [String: Any]? {
        guard let payload = data.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        return object as? [String: Any]
    }

    private static func deltaText(previous: String, current: String) -> String {
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }
        return current
    }
}

private struct GeminiPendingToolCall: Sendable {
    var id: String?
    var name: String?
    var arguments: String = ""
}
