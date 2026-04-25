import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI

@MainActor
struct SlashCommandContext {
    let agent: Agent
    let modelStore: ModelStore?
}

@MainActor
struct SlashCommand {
    let names: [String]
    let usage: String
    let summary: String
    let handler: @MainActor @Sendable (_ argument: String?, _ context: SlashCommandContext) -> PromptController.SubmitResult

    init(
        names: [String],
        usage: String,
        summary: String,
        handler: @escaping @MainActor @Sendable (_ argument: String?, _ context: SlashCommandContext) -> PromptController.SubmitResult
    ) {
        self.names = names
        self.usage = usage
        self.summary = summary
        self.handler = handler
    }

    var primaryName: String {
        names.first ?? ""
    }

    func matches(_ name: String) -> Bool {
        names.contains(name)
    }

    var helpLine: String {
        let label = names.joined(separator: ", ")
        let padded = label.padding(toLength: 14, withPad: " ", startingAt: 0)
        return "  \(padded) \(summary)"
    }
}

@MainActor
struct SlashCommandRegistry {
    let commands: [SlashCommand]

    func command(named name: String) -> SlashCommand? {
        commands.first(where: { $0.matches(name) })
    }

    func execute(_ text: String, context: SlashCommandContext) -> PromptController.SubmitResult {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let commandName = parts.first.map(String.init) else {
            return .feedback("Unknown command")
        }

        guard let command = command(named: commandName) else {
            return .feedback("Unknown command: \(commandName). Available: \(availableCommandList)")
        }

        let argument = parts.count > 1 ? String(parts[1]) : nil
        return command.handler(argument, context)
    }

    var availableCommandList: String {
        commands.map(\.primaryName).joined(separator: ", ")
    }

    func helpText() -> String {
        let lines = commands.map(\.helpLine).joined(separator: "\n")
        return """
        Available commands:
        \(lines)
        """
    }
}

@MainActor
func makeDefaultSlashCommandRegistry() -> SlashCommandRegistry {
    SlashCommandRegistry(
        commands: [
            SlashCommand(
                names: ["/model"],
                usage: "/model [id]",
                summary: "Open picker or switch model"
            ) { argument, context in
                let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.isEmpty {
                    let model = context.agent.state.model
                    if context.agent.state.isStreaming {
                        return .feedback("Current model: \(model.name) (\(model.id))")
                    }
                    return .showModelPicker(makeModelPickerState(currentModel: model))
                }

                context.agent.state.model = switchedModel(from: context.agent.state.model, to: trimmed)
                context.modelStore?.save(context.agent.state.model)
                return .feedback("Switched to model: \(trimmed)")
            },
            SlashCommand(
                names: ["/compact"],
                usage: "/compact",
                summary: "Compact conversation context"
            ) { _, context in
                let before = context.agent.state.messages.count
                context.agent.state.compact()
                let after = context.agent.state.messages.count
                return .feedback("Compacted context: \(before) → \(after) messages")
            },
            SlashCommand(
                names: ["/help"],
                usage: "/help",
                summary: "Show this help"
            ) { _, _ in
                .feedback(makeDefaultSlashCommandRegistry().helpText())
            },
            SlashCommand(
                names: ["/exit", "/quit"],
                usage: "/exit",
                summary: "Exit the application"
            ) { _, _ in
                .exit
            },
        ]
    )
}
