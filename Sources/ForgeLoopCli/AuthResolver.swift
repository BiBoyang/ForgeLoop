import Foundation
import ForgeLoopAI

struct ResolvedAuth: Sendable {
    let model: Model
}

func resolveAgentAuth(
    modelOverride: String? = nil,
    modelStore: ModelStore = ModelStore()
) async throws -> ResolvedAuth {
    _ = await registerBuiltins()

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
