import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopTUI

public func suggestedModelPickerItems(for currentModel: Model) -> [ListPickerItem] {
    let preferredIDs: [String]
    let normalizedBaseURL = currentModel.baseUrl.lowercased()
    let normalizedID = currentModel.id.lowercased()

    switch currentModel.provider {
    case "faux":
        preferredIDs = [
            currentModel.id,
            "faux-coding-model",
            "gpt-4.1-mini",
            "gpt-4o",
            "o4-mini",
        ]
    case _ where normalizedBaseURL.contains("deepseek.com") || normalizedID.hasPrefix("deepseek-"):
        preferredIDs = [
            currentModel.id,
            "deepseek-chat",
            "deepseek-reasoner",
        ]
    default:
        preferredIDs = [
            currentModel.id,
            "gpt-4.1-mini",
            "gpt-4.1",
            "gpt-4o",
            "o4-mini",
        ]
    }

    var seen = Set<String>()
    return preferredIDs.compactMap { id in
        guard seen.insert(id).inserted else { return nil }

        let subtitle: String
        if id == currentModel.id {
            subtitle = "Current • api: \(currentModel.api) • provider: \(currentModel.provider)"
        } else if currentModel.baseUrl.isEmpty {
            subtitle = "Switch with current api/provider settings"
        } else {
            subtitle = "Switch with current api/provider settings • baseURL preserved"
        }

        return ListPickerItem(id: id, title: id, subtitle: subtitle)
    }
}

func makeModelPickerState(currentModel: Model) -> ListPickerState {
    let items = suggestedModelPickerItems(for: currentModel)
    let selectedIndex = items.firstIndex(where: { $0.id == currentModel.id }) ?? 0
    return ListPickerState(
        title: "Select model",
        subtitle: "Current: \(currentModel.name) (\(currentModel.id))",
        items: items,
        selectedIndex: selectedIndex,
        footer: "(↑↓ to select, Enter to confirm, Esc to cancel, or type /model <id>)"
    )
}

@MainActor
public struct PromptController {
    /// Deprecated: use top-level `SubmitResult` instead.
    public typealias SubmitResult = ForgeLoopCli.SubmitResult

    private let coordinator: SessionCoordinator
    let agent: Agent

    init(
        agent: Agent,
        modelStore: ModelStore? = nil,
        attachmentStore: AttachmentStore = AttachmentStore(),
        sessionStore: SessionStore = SessionStore(),
        slashCommandRegistry: SlashCommandRegistry = makeDefaultSlashCommandRegistry()
    ) {
        self.agent = agent
        self.coordinator = SessionCoordinator(
            agent: agent,
            modelStore: modelStore,
            attachmentStore: attachmentStore,
            sessionStore: sessionStore,
            slashCommandRegistry: slashCommandRegistry
        )
    }

    func submit(_ text: String) async throws -> SubmitResult {
        try await coordinator.submit(text)
    }

    func handleSlashCommand(_ text: String) async -> SubmitResult {
        await coordinator.handleSlashCommand(text)
    }
}
