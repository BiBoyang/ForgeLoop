import Foundation

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
}

public struct Context: Sendable, Hashable, Codable {
    public var systemPrompt: String?
    public var messages: [Message]

    public init(systemPrompt: String? = nil, messages: [Message] = []) {
        self.systemPrompt = systemPrompt
        self.messages = messages
    }
}

public struct StreamOptions: Sendable {
    public var apiKey: String?
    public var cancellation: CancellationHandle?

    public init(apiKey: String? = nil, cancellation: CancellationHandle? = nil) {
        self.apiKey = apiKey
        self.cancellation = cancellation
    }
}
