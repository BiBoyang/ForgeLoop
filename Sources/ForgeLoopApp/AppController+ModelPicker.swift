import AppKit
import Foundation
import ForgeLoopCli

// MARK: - Model Picker

extension AppController {
    func populateModelPicker() {
        guard !tabs.isEmpty, let picker = modelPicker else { return }
        let agent = activeTab.agent
        let items = suggestedModelPickerItems(for: agent.state.model)
        picker.removeAllItems()
        modelPickerIDs = items.map { $0.id }
        for item in items {
            picker.addItem(withTitle: item.title)
        }
        if let index = items.firstIndex(where: { $0.id == agent.state.model.id }) {
            picker.selectItem(at: index)
        }
    }

    @objc func modelPickerChanged(_ sender: NSPopUpButton) {
        guard !tabs.isEmpty else { return }
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < modelPickerIDs.count else { return }
        let modelID = modelPickerIDs[index]
        guard modelID != activeTab.agent.state.model.id else { return }
        Task { @MainActor in
            await diagnostics.log.log(
                level: .info,
                message: "app.model.switch",
                attributes: [
                    "from_model": .string(activeTab.agent.state.model.id),
                    "to_model": .string(modelID)
                ]
            )
            try? await activeTab.coordinator.switchModel(to: modelID)
            populateModelPicker()
            render()
        }
    }
}
