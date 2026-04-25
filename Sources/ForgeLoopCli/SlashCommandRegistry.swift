import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI

@MainActor
struct SlashCommandContext {
    let agent: Agent
    let modelStore: ModelStore?
    let attachmentStore: AttachmentStore
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

/// 提取 queued message 的单行预览文本，统一归一化与截断。
func queueMessagePreview(_ message: Message) -> String {
    let raw: String
    switch message {
    case .user(let userMessage):
        raw = userMessage.text
    case .assistant(let assistantMessage):
        let textBlocks = assistantMessage.content.compactMap { block -> String? in
            if case .text(let content) = block { return content.text }
            if case .toolCall(let call) = block { return "[tool: \(call.name)]" }
            return nil
        }
        raw = textBlocks.joined(separator: " ")
    case .tool(let toolMessage):
        raw = toolMessage.output
    }

    let normalized = raw
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    let trimmed = normalized.trimmingCharacters(in: .whitespaces)
    let maxLength = 50
    return trimmed.count > maxLength
        ? String(trimmed.prefix(maxLength)) + "..."
        : trimmed
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
                names: ["/queue"],
                usage: "/queue [clear]",
                summary: "Show or clear queued steering messages"
            ) { argument, context in
                let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if trimmed == "clear" {
                    let count = context.agent.queuedSteeringMessages().count
                    context.agent.clearSteeringQueue()
                    return .feedback("Cleared \(count) queued message\(count == 1 ? "" : "s")")
                }

                let queue = context.agent.queuedSteeringMessages()
                if queue.isEmpty {
                    return .feedback("Queue is empty")
                }

                let maxVisible = 5
                let visible = queue.prefix(maxVisible)
                let lines = visible.enumerated().map { index, message in
                    "  \(index + 1). \(queueMessagePreview(message))"
                }
                var result = "Queue (\(queue.count)):\n" + lines.joined(separator: "\n")
                if queue.count > maxVisible {
                    result += "\n  ... and \(queue.count - maxVisible) more"
                }
                return .feedback(result)
            },
            SlashCommand(
                names: ["/attach"],
                usage: "/attach text <content> | /attach path <path>",
                summary: "Add an attachment"
            ) { argument, context in
                let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.isEmpty {
                    return .feedback("Usage: /attach text <content> or /attach path <path>")
                }

                let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count >= 2 else {
                    return .feedback("Usage: /attach text <content> or /attach path <path>")
                }

                let kind = String(parts[0])
                let content = String(parts[1])

                switch kind {
                case "text":
                    let record = context.attachmentStore.addText(content)
                    return .feedback("Attached text: \(record.displayPreview)")
                case "path":
                    let record = context.attachmentStore.addFilePath(content)
                    return .feedback("Attached path: \(record.displayPreview)")
                default:
                    return .feedback("Unknown attachment kind: \(kind). Use 'text' or 'path'.")
                }
            },
            SlashCommand(
                names: ["/attachments"],
                usage: "/attachments [clear]",
                summary: "List or clear attachments"
            ) { argument, context in
                let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if trimmed == "clear" {
                    let count = context.attachmentStore.count
                    context.attachmentStore.clear()
                    return .feedback("Cleared \(count) attachment\(count == 1 ? "" : "s")")
                }

                let records = context.attachmentStore.list()
                if records.isEmpty {
                    return .feedback("No attachments")
                }
                let lines = records.enumerated().map { index, record in
                    "  \(index + 1). \(record.displayPreview)"
                }
                return .feedback("Attachments (\(records.count)):\n" + lines.joined(separator: "\n"))
            },
            SlashCommand(
                names: ["/detach"],
                usage: "/detach <index> | /detach all",
                summary: "Remove attachment(s)"
            ) { argument, context in
                let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.isEmpty {
                    return .feedback("Usage: /detach <index> or /detach all")
                }

                if trimmed == "all" {
                    let count = context.attachmentStore.count
                    context.attachmentStore.clear()
                    return .feedback("Cleared \(count) attachment\(count == 1 ? "" : "s")")
                }

                guard let index = Int(trimmed), index > 0 else {
                    return .feedback("Invalid index: \(trimmed)")
                }

                let removed = context.attachmentStore.remove(at: index - 1)
                if removed {
                    return .feedback("Removed attachment #\(index)")
                } else {
                    return .feedback("No attachment at index \(index)")
                }
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
