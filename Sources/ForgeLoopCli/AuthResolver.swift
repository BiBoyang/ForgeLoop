import Foundation
import ForgeLoopAI

struct ResolvedAuth: Sendable {
    let model: Model
}

enum AuthError: Error, CustomStringConvertible {
    case missingCredentials(provider: String)

    var description: String {
        switch self {
        case .missingCredentials(let provider):
            return "Missing API key for provider '\(provider)'. Run 'forgeloop login' to set credentials."
        }
    }
}

enum LoginError: Error, CustomStringConvertible {
    case missingAPIKey

    var description: String {
        "API key is required. Please provide a valid API key."
    }
}

func resolveAgentAuth(
    modelOverride: String? = nil,
    modelStore: ModelStore = ModelStore(),
    credentialStore: CredentialStore = CredentialStore(),
    environment: [String: String] = ProcessInfo.processInfo.environment
) async throws -> ResolvedAuth {
    let storedKey = credentialStore.load()
    let registered = await registerBuiltins(environment: environment, storedAPIKey: storedKey)
    let hasCredentials = registered.count > 1 // non-faux provider registered

    // Priority 1: CLI explicit override
    if let override = modelOverride, !override.isEmpty {
        let model = Model(
            id: override,
            name: override,
            api: "faux",
            provider: "faux",
            baseUrl: ""
        )
        return ResolvedAuth(model: model)
    }

    // Priority 2: stored model
    if let storedModel = modelStore.load() {
        if storedModel.provider != "faux" && !hasCredentials {
            throw AuthError.missingCredentials(provider: storedModel.provider)
        }
        return ResolvedAuth(model: storedModel)
    }

    // Priority 3: default fallback
    let model = Model(
        id: "faux-coding-model",
        name: "Faux Coding Model",
        api: "faux",
        provider: "faux",
        baseUrl: ""
    )
    return ResolvedAuth(model: model)
}
