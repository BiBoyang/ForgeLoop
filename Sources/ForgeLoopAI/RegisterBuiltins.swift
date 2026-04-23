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
        !apiKey.isEmpty
    {
        let responses = OpenAIResponsesProvider(defaultAPIKey: apiKey)
        await APIRegistry.shared.register(responses, sourceId: sourceId)
        registered.append(responses.api)

        let completions = OpenAIChatCompletionsProvider(defaultAPIKey: apiKey)
        await APIRegistry.shared.register(completions, sourceId: sourceId)
        registered.append(completions.api)
    }

    return registered
}
