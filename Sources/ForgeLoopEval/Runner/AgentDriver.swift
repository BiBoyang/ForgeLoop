import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopCli
import ForgeLoopDiagnostics

/// Drives a single `EvalCase` to completion using a `SessionCoordinator`.
///
/// `AgentDriver` is not isolated to any global actor. `SessionCoordinator` is
/// `@MainActor`, so the actual work is delegated to a private `@MainActor`
/// method. The public entry point simply hops to the main actor and returns the
/// `Sendable` result.
public final class AgentDriver: @unchecked Sendable {
    private let diagnostics: Diagnostics

    public init(diagnostics: Diagnostics = Diagnostics()) {
        self.diagnostics = diagnostics
    }

    /// Run a single eval case to completion in the given workspace.
    public func run(
        case evalCase: EvalCase,
        workspace: Workspace,
        config: EvalConfig
    ) async -> AgentDriverResult {
        await runOnMainActor(case: evalCase, workspace: workspace, config: config)
    }

    @MainActor
    private func runOnMainActor(
        case evalCase: EvalCase,
        workspace: Workspace,
        config: EvalConfig
    ) async -> AgentDriverResult {
        let provider = await resolveProvider(name: config.providerName)
        let model = Model(
            id: "\(config.providerName)-eval-model",
            name: "Eval Model",
            api: provider.api,
            provider: config.providerName,
            baseUrl: ""
        )

        let rootURL = await workspace.rootURL
        let cwd = rootURL.path

        let agent = await makeCodingAgent(
            CodingAgentConfig(
                model: model,
                cwd: cwd,
                streamFn: { model, context, options in
                    await provider.stream(model: model, context: context, options: options)
                }
            ),
            diagnostics: diagnostics
        )

        let completion = CompletionState()

        let unsubscribe = agent.subscribe { event, _ in
            if case .agentEnd(let messages) = event {
                await completion.complete(messages: messages)
            }
        }
        defer { unsubscribe() }

        let coordinator = SessionCoordinator(agent: agent, diagnostics: diagnostics)

        var runError: Error?
        do {
            let submitResult = try await coordinator.submit(evalCase.prompt)
            if case .feedback(let message) = submitResult {
                runError = AgentDriverError.coordinatorSubmitFailed(message: message)
            }
        } catch {
            runError = error
        }

        // Wait for the agent to finish streaming and executing tools.
        await agent.waitForIdle()
        let finalMessages = await completion.messages()

        await agent.closeSession()

        return AgentDriverResult(
            messages: finalMessages,
            error: runError
        )
    }

    /// Resolve a provider by name, falling back to the built-in Faux provider.
    ///
    /// If a provider with the requested API is already registered, it is reused
    /// without calling `registerBuiltins`, so tests and callers can inject a
    /// custom provider without it being overwritten.
    private func resolveProvider(name: String) async -> APIProvider {
        if let provider = await APIRegistry.shared.provider(for: name) {
            return provider
        }

        // Ensure builtins (at least Faux) are registered.
        _ = await registerBuiltins(sourceId: "forgeloop-eval-builtins")

        if let provider = await APIRegistry.shared.provider(for: name) {
            return provider
        }
        return FauxProvider(api: name)
    }
}

/// The outcome of an `AgentDriver.run` call.
public struct AgentDriverResult: Sendable {
    public let messages: [Message]
    public let error: Error?

    public init(messages: [Message], error: Error?) {
        self.messages = messages
        self.error = error
    }
}

public enum AgentDriverError: Error, LocalizedError {
    case coordinatorSubmitFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .coordinatorSubmitFailed(let message):
            return "SessionCoordinator submit failed: \(message)"
        }
    }
}

/// Thread-safe holder for the final messages produced by the agent run.
private actor CompletionState {
    private var finalMessages: [Message] = []
    private var isComplete = false
    private var continuation: CheckedContinuation<[Message], Never>?

    func complete(messages: [Message]) {
        finalMessages = messages
        isComplete = true
        continuation?.resume(returning: messages)
        continuation = nil
    }

    func messages() async -> [Message] {
        if isComplete { return finalMessages }
        return await withCheckedContinuation { cont in
            continuation = cont
        }
    }
}
