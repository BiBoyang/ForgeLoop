import Foundation
import ForgeLoopDiagnostics

public protocol APIProvider: Sendable {
    var api: String { get }
    func stream(model: Model, context: Context, options: StreamOptions?) async -> AssistantMessageStream
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

public func stream(
    model: Model,
    context: Context,
    options: StreamOptions? = nil
) async throws -> AssistantMessageStream {
    let diagnostics = options?.diagnostics ?? Diagnostics()
    let span = await diagnostics.trace.startSpan(
        name: "provider.stream",
        parent: options?.traceContext,
        layer: "AI",
        operation: "stream",
        attributes: [
            "api": .string(model.api),
            "model_id": .string(model.id),
            "provider": .string(model.provider)
        ]
    )

    guard let provider = await APIRegistry.shared.provider(for: model.api) else {
        await diagnostics.trace.endSpan(
            span,
            attributes: [:],
            error: TraceError(
                type: "ProviderNotFound",
                message: "No provider for api: \(model.api)"
            )
        )
        throw ProviderNotFoundError.api(model.api)
    }

    let stream = await provider.stream(
        model: model,
        context: context,
        options: options
    )
    await diagnostics.trace.endSpan(span, attributes: [:], error: nil)
    return stream
}

public func complete(
    model: Model,
    context: Context,
    options: StreamOptions? = nil
) async throws -> AssistantMessage {
    let messageStream = try await stream(model: model, context: context, options: options)
    for await _ in messageStream {}
    return await messageStream.result()
}
