import Foundation

public protocol APIProvider: Sendable {
    var api: String { get }
    func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream
}

public actor APIRegistry {
    public static let shared = APIRegistry()

    private var providers: [String: APIProvider] = [:]
    private var bySource: [String: Set<String>] = [:]

    public init() {}

    public func register(_ provider: APIProvider, sourceId: String? = nil) {
        providers[provider.api] = provider
        if let sourceId {
            bySource[sourceId, default: []].insert(provider.api)
        }
    }

    public func provider(for api: String) -> APIProvider? {
        providers[api]
    }

    public func unregisterSource(_ sourceId: String) {
        guard let apis = bySource.removeValue(forKey: sourceId) else { return }
        for api in apis {
            providers.removeValue(forKey: api)
        }
    }
}

public enum ProviderNotFoundError: Error, LocalizedError, Equatable {
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .api(let api): return "No provider registered for api: \(api)"
        }
    }
}

public func stream(model: Model, context: Context, options: StreamOptions? = nil) async throws -> AssistantMessageStream {
    guard let provider = await APIRegistry.shared.provider(for: model.api) else {
        throw ProviderNotFoundError.api(model.api)
    }
    return provider.stream(model: model, context: context, options: options)
}

public func complete(model: Model, context: Context, options: StreamOptions? = nil) async throws -> AssistantMessage {
    let messageStream = try await stream(model: model, context: context, options: options)
    for await _ in messageStream {}
    return await messageStream.result()
}
