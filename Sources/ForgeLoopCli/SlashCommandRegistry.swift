import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI

@MainActor
public struct SlashCommandContext {
    public let agent: Agent
    public let modelStore: ModelStore?
    public let attachmentStore: AttachmentStore
    public let sessionStore: SessionStore

    public init(
        agent: Agent,
        modelStore: ModelStore? = nil,
        attachmentStore: AttachmentStore,
        sessionStore: SessionStore = SessionStore()
    ) {
        self.agent = agent
        self.modelStore = modelStore
        self.attachmentStore = attachmentStore
        self.sessionStore = sessionStore
    }
}

@MainActor
struct SlashCommand {
    let names: [String]
    let usage: String
    let summary: String
    let handler: @MainActor @Sendable (_ argument: String?, _ context: SlashCommandContext) async -> PromptController.SubmitResult

    init(
        names: [String],
        usage: String,
        summary: String,
        handler: @escaping @MainActor @Sendable (_ argument: String?, _ context: SlashCommandContext) async -> PromptController.SubmitResult
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
public struct SlashCommandRegistry {
    let commands: [SlashCommand]

    func command(named name: String) -> SlashCommand? {
        commands.first(where: { $0.matches(name) })
    }

    public func execute(_ text: String, context: SlashCommandContext) async -> PromptController.SubmitResult {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let commandName = parts.first.map(String.init) else {
            return .feedback("Unknown command")
        }

        guard let command = command(named: commandName) else {
            return .feedback("Unknown command: \(commandName). Available: \(availableCommandList)")
        }

        let argument = parts.count > 1 ? String(parts[1]) : nil
        return await command.handler(argument, context)
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
public func makeDefaultSlashCommandRegistry() -> SlashCommandRegistry {
    SlashCommandRegistry(
        commands: [
            SlashCommand(
                names: ["/model"],
                usage: "/model [id]",
                summary: "Open picker or switch model"
            ) { argument, context async in
                let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.isEmpty {
                    let model = context.agent.state.model
                    if context.agent.state.isStreaming {
                        return .feedback("Current model: \(model.name) (\(model.id))")
                    }
                    return .showModelPicker(makeModelPickerState(currentModel: model))
                }

                let newModel = context.agent.state.model.switched(to: trimmed)
                do {
                    try await context.agent.switchModel(to: newModel)
                    context.modelStore?.save(context.agent.state.model)
                    return .feedback("Switched to model: \(trimmed)")
                } catch {
                    return .feedback("Failed to switch model: \(error)")
                }
            },
            SlashCommand(
                names: ["/compact"],
                usage: "/compact",
                summary: "Compact conversation context"
            ) { _, context in
                let before = context.agent.state.messages.count
                do {
                    try await context.agent.compactContext()
                    let after = context.agent.state.messages.count
                    return .feedback("Compacted context: \(before) → \(after) messages")
                } catch {
                    return .feedback("Failed to compact context: \(error)")
                }
            },
            SlashCommand(
                names: ["/queue"],
                usage: "/queue [clear]",
                summary: "Show or clear queued steering messages"
            ) { argument, context async in
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
            ) { argument, context async in
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
            ) { argument, context async in
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
            ) { argument, context async in
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
                names: ["/save"],
                usage: "/save [name]",
                summary: "Save current session"
            ) { argument, context async in
                if context.agent.state.isStreaming {
                    return .feedback("Cannot save while streaming")
                }

                let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = trimmed.isEmpty ? "last" : trimmed

                do {
                    try context.sessionStore.save(
                        name: name,
                        modelID: context.agent.state.model.id,
                        messages: context.agent.state.messages
                    )
                    let count = context.agent.state.messages.count
                    return .feedback("Saved session: \(name) (\(count) messages)")
                } catch {
                    return .feedback("Failed to save session: \(error)")
                }
            },
            SlashCommand(
                names: ["/load"],
                usage: "/load <name>",
                summary: "Load a saved session"
            ) { argument, context async in
                if context.agent.state.isStreaming {
                    return .feedback("Cannot load while streaming")
                }

                let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !trimmed.isEmpty else {
                    return .feedback("Usage: /load <name>")
                }

                do {
                    guard let record = try context.sessionStore.load(name: trimmed) else {
                        return .feedback("Session not found: \(trimmed)")
                    }

                    try await context.agent.restoreSession(
                        messages: record.messages,
                        modelID: record.modelID
                    )
                    context.modelStore?.save(context.agent.state.model)

                    return .feedback("Loaded session: \(trimmed) (\(record.messages.count) messages)")
                } catch {
                    return .feedback("Failed to load session: \(error)")
                }
            },
            SlashCommand(
                names: ["/sessions"],
                usage: "/sessions",
                summary: "List saved sessions"
            ) { _, context in
                do {
                    let names = try context.sessionStore.list()
                    if names.isEmpty {
                        return .feedback("No saved sessions")
                    }

                    let lines = names.map { name -> String in
                        if let record = try? context.sessionStore.load(name: name) {
                            return "  \(name) (\(record.messages.count) messages)"
                        }
                        return "  \(name)"
                    }
                    return .feedback("Saved sessions:\n" + lines.joined(separator: "\n"))
                } catch {
                    return .feedback("Failed to list sessions: \(error)")
                }
            },
            SlashCommand(
                names: ["/export"],
                usage: "/export [name]",
                summary: "Export conversation as Markdown to the desktop"
            ) { argument, context async in
                let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fileName = trimmed.isEmpty ? "forgeloop-export.md" : "\(trimmed).md"

                guard let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
                    return .feedback("Could not locate Desktop directory")
                }
                let targetURL = desktopURL.appendingPathComponent(fileName)

                var lines: [String] = []
                for message in context.agent.state.messages {
                    switch message {
                    case .user(let userMessage):
                        lines.append("**You:** \(userMessage.text)")
                    case .assistant(let assistantMessage):
                        let textBlocks = assistantMessage.content.compactMap { block -> String? in
                            if case .text(let content) = block { return content.text }
                            return nil
                        }
                        if !textBlocks.isEmpty {
                            lines.append("**Assistant:** \(textBlocks.joined(separator: " "))")
                        }
                    case .tool(let toolMessage):
                        lines.append("**Tool \(toolMessage.toolCallId):** \(toolMessage.output)")
                    }
                }

                let content = lines.joined(separator: "\n\n")
                do {
                    try content.write(to: targetURL, atomically: true, encoding: .utf8)
                    return .feedback("Exported conversation to \(targetURL.path)")
                } catch {
                    return .feedback("Failed to export conversation: \(error)")
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
