import Foundation
import ForgeLoopAI
import ForgeLoopAgent

@MainActor
struct PromptController {
    let agent: Agent
    var modelStore: ModelStore?

    enum SubmitResult: Equatable {
        case submitted
        case feedback(String)
        case exit
    }

    init(agent: Agent, modelStore: ModelStore? = nil) {
        self.agent = agent
        self.modelStore = modelStore
    }

    func submit(_ text: String) async throws -> SubmitResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed == "/exit" || trimmed == "/quit" {
            return .exit
        }

        if trimmed.hasPrefix("/") {
            return await handleSlashCommand(trimmed)
        }

        if agent.state.isStreaming {
            agent.steer(.user(UserMessage(text: trimmed)))
            return .submitted
        } else {
            try await agent.prompt(trimmed)
            return .submitted
        }
    }

    private func handleSlashCommand(_ text: String) async -> SubmitResult {
        let parts = text.split(separator: " ", maxSplits: 1)
        guard let command = parts.first else {
            return .feedback("Unknown command")
        }

        switch command {
        case "/model":
            return handleModelCommand(parts)
        case "/compact":
            return handleCompactCommand()
        case "/help":
            return handleHelpCommand()
        default:
            return .feedback("Unknown command: \(command). Available: /help, /model, /compact, /exit")
        }
    }

    private func handleModelCommand(_ parts: [Substring]) -> SubmitResult {
        if parts.count == 1 {
            let model = agent.state.model
            return .feedback("Current model: \(model.name) (\(model.id))")
        }
        let modelId = String(parts[1]).trimmingCharacters(in: .whitespaces)
        guard !modelId.isEmpty else {
            return .feedback("Usage: /model <model-id>")
        }
        let current = agent.state.model
        agent.state.model = Model(
            id: modelId,
            name: modelId,
            api: current.api,
            provider: current.provider,
            baseUrl: current.baseUrl
        )
        modelStore?.save(agent.state.model)
        return .feedback("Switched to model: \(modelId)")
    }

    private func handleHelpCommand() -> SubmitResult {
        .feedback("""
        Available commands:
          /model [id]   Show or switch model
          /compact      Compact conversation context
          /help         Show this help
          /exit, /quit  Exit the application
        """)
    }

    private func handleCompactCommand() -> SubmitResult {
        let before = agent.state.messages.count
        agent.state.compact()
        let after = agent.state.messages.count
        return .feedback("Compacted context: \(before) → \(after) messages")
    }
}
