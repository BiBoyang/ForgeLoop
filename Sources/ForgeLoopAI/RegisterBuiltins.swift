import Foundation

@discardableResult
public func registerBuiltins(
    sourceId: String = "forgeloop-replica-builtins",
    environment: [String: String] = ProcessInfo.processInfo.environment,
    storedAPIKey: String? = nil
) async -> [String] {
    let faux = FauxProvider()
    await APIRegistry.shared.register(faux, sourceId: sourceId)
    var registered = [faux.api]

    let openAIKey = environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let deepSeekKey = environment["DEEPSEEK_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let storedKey = storedAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    let compatibleKey = [storedKey, openAIKey, deepSeekKey].compactMap { $0 }.first { !$0.isEmpty }

    if
        let apiKey = compatibleKey,
        !apiKey.isEmpty {
        let responses = OpenAIResponsesProvider(defaultAPIKey: apiKey)
        await APIRegistry.shared.register(responses, sourceId: sourceId)
        registered.append(responses.api)

        let completions = OpenAIChatCompletionsProvider(defaultAPIKey: apiKey)
        await APIRegistry.shared.register(completions, sourceId: sourceId)
        registered.append(completions.api)
    }

    let anthropicKey = environment["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let apiKey = anthropicKey, !apiKey.isEmpty {
        let anthropic = AnthropicProvider(defaultAPIKey: apiKey)
        await APIRegistry.shared.register(anthropic, sourceId: sourceId)
        registered.append(anthropic.api)
    }

    let geminiKey = environment["GEMINI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let apiKey = geminiKey, !apiKey.isEmpty {
        let gemini = GeminiProvider(defaultAPIKey: apiKey)
        await APIRegistry.shared.register(gemini, sourceId: sourceId)
        registered.append(gemini.api)
    }

    return registered
}
