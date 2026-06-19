import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopDiagnostics

/// Platform-agnostic coordinator for a single agent session.
///
/// `SessionCoordinator` owns the shared state and operations that both the TUI
/// (`PromptController` / `CodingTUI`) and the AppKit frontend need:
/// - the `Agent`
/// - the `AttachmentStore`
/// - slash-command execution
/// - model switching
/// - session save / restore
///
/// Platform-specific code (TUI input loop, AppKit views) should call into the
/// coordinator instead of duplicating these rules.
@MainActor
public final class SessionCoordinator {
    public let agent: Agent
    public let attachmentStore: AttachmentStore
    public private(set) var modelStore: ModelStore?
    public let sessionStore: SessionStore

    private let slashCommandRegistry: SlashCommandRegistry
    private let diagnostics: Diagnostics
    private let masker = SensitiveDataMasker()

    public init(
        agent: Agent,
        modelStore: ModelStore? = nil,
        attachmentStore: AttachmentStore = AttachmentStore(),
        sessionStore: SessionStore = SessionStore(),
        slashCommandRegistry: SlashCommandRegistry = makeDefaultSlashCommandRegistry(),
        diagnostics: Diagnostics = Diagnostics()
    ) {
        self.agent = agent
        self.modelStore = modelStore
        self.attachmentStore = attachmentStore
        self.sessionStore = sessionStore
        self.slashCommandRegistry = slashCommandRegistry
        self.diagnostics = diagnostics
    }

    /// Submits user input. Handles slash commands, attachment injection, and
    /// steering/prompt dispatch.
    public func submit(_ text: String) async throws -> SubmitResult {
        let span = await diagnostics.trace.startSpan(
            name: "session.submit",
            parent: nil,
            layer: "Cli",
            operation: "submit",
            attributes: ["has_slash_command": .bool(text.hasPrefix("/"))]
        )
        var submitError: TraceError?
        defer {
            let capturedError = submitError
            Task {
                await diagnostics.trace.endSpan(span, attributes: [:], error: capturedError)
            }
        }

        let maskedText = await masker.mask(text, preservePrefixLength: 20)
        await diagnostics.log.log(
            level: .debug,
            message: "session.submit.start",
            attributes: [
                "text_preview": .masked(maskedText),
                "is_streaming": .bool(agent.state.isStreaming)
            ]
        )

        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("/") {
                return await handleSlashCommand(trimmed)
            }

            let finalText = injectAttachments(into: trimmed, attachments: attachmentStore.snapshot())

            guard !finalText.isEmpty else {
                return .submitted
            }

            if agent.state.isStreaming {
                agent.steer(.user(UserMessage(text: finalText)))
                return .submitted
            } else {
                try await agent.prompt(finalText)
                return .submitted
            }
        } catch {
            submitError = TraceError(type: String(describing: type(of: error)), message: "\(error)")
            throw error
        }
    }

    /// Executes a slash command through the shared registry.
    public func handleSlashCommand(_ text: String) async -> SubmitResult {
        await slashCommandRegistry.execute(
            text,
            context: SlashCommandContext(
                agent: agent,
                modelStore: modelStore,
                attachmentStore: attachmentStore,
                sessionStore: sessionStore
            )
        )
    }

    /// Switches the session model and persists it to the model store.
    public func switchModel(to modelID: String) async throws {
        await diagnostics.log.log(
            level: .info,
            message: "session.switch_model",
            attributes: [
                "from_model": .string(agent.state.model.id),
                "to_model": .string(modelID)
            ]
        )
        let newModel = agent.state.model.switched(to: modelID)
        try await agent.switchModel(to: newModel)
        modelStore?.save(agent.state.model)
    }

    /// Restores the last session from disk, if one exists.
    public func restoreLastSession() async throws {
        await diagnostics.log.log(
            level: .info,
            message: "session.restore_last",
            attributes: ["has_last_session": .bool((try? sessionStore.load(name: "last")) != nil)]
        )
        if let last = try? sessionStore.load(name: "last"), !last.messages.isEmpty {
            try await agent.restoreSession(messages: last.messages, modelID: last.modelID)
            modelStore?.save(agent.state.model)
        }
    }

    /// Saves the current messages as the named session.
    public func saveCurrentSession(name: String) async throws {
        await diagnostics.log.log(
            level: .info,
            message: "session.save",
            attributes: [
                "name": .string(name),
                "message_count": .int(agent.state.messages.count)
            ]
        )
        try sessionStore.save(
            name: name,
            modelID: agent.state.model.id,
            messages: agent.state.messages
        )
    }

    /// Returns a snapshot of the current model label for status rendering.
    public func currentModelLabel() -> String {
        labelForModel(agent.state.model)
    }
}
