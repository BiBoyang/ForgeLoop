import Foundation
import ForgeLoopDiagnostics

public struct Model: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var api: String
    public var provider: String
    public var baseUrl: String

    public init(
        id: String,
        name: String,
        api: String,
        provider: String,
        baseUrl: String = ""
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.provider = provider
        self.baseUrl = baseUrl
    }

    /// Returns a new Model with the same api/provider/baseUrl but a different id/name.
    public func switched(to newID: String) -> Model {
        Model(
            id: newID,
            name: newID,
            api: api,
            provider: provider,
            baseUrl: baseUrl
        )
    }
}

public struct Context: Sendable, Hashable, Codable {
    public var systemPrompt: String?
    public var messages: [Message]

    public init(systemPrompt: String? = nil, messages: [Message] = []) {
        self.systemPrompt = systemPrompt
        self.messages = messages
    }
}

public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let parametersJSON: Data

    public init(name: String, description: String, parameters: [String: Any]) throws {
        self.name = name
        self.description = description
        self.parametersJSON = try JSONSerialization.data(withJSONObject: parameters)
    }

    public init(name: String, description: String, parametersJSON: Data) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public struct StreamOptions: Sendable {
    public var apiKey: String?
    public var cancellation: CancellationHandle?
    public var tools: [ToolDefinition]?
    public var toolChoice: String?
    public var traceContext: TraceContext?
    public var diagnostics: Diagnostics?

    public init(
        apiKey: String? = nil,
        cancellation: CancellationHandle? = nil,
        tools: [ToolDefinition]? = nil,
        toolChoice: String? = nil,
        traceContext: TraceContext? = nil,
        diagnostics: Diagnostics? = nil
    ) {
        self.apiKey = apiKey
        self.cancellation = cancellation
        self.tools = tools
        self.toolChoice = toolChoice
        self.traceContext = traceContext
        self.diagnostics = diagnostics
    }
}
