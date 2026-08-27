import AppKit
import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopCli
import ForgeLoopTUI

// MARK: - Tabs

extension AppController {
    func setupSubscriptions(for tab: TabSession) {
        _ = tab.agent.subscribe { @MainActor [weak self, weak tab] event, _ in
            guard let self, let tab else { return }
            switch event {
            case .messageStart(message: .assistant):
                tab.currentBlockID = UUID().uuidString
            case .messageEnd(message: .assistant):
                tab.currentBlockID = nil
            default:
                break
            }
            let blockID = tab.currentBlockID ?? "__assistant"
            for coreEvent in toCoreRenderEvent(event, blockID: blockID) {
                tab.transcript.applyCore(coreEvent)
            }
            self.render()
        }
        observeActivity(of: tab)
    }

    func restoreTabs(resolved: ResolvedAuth) async {
        let metaURL = sessionStore.sessionsDirectory().appendingPathComponent("tab-meta.json")
        guard FileManager.default.fileExists(atPath: metaURL.path),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(TabMeta.self, from: metaData) else {
            // No tab metadata yet. Try to migrate a previous "last" session into the first tab.
            if let last = try? sessionStore.load(name: "last"), !last.messages.isEmpty {
                let agent = await makeCodingAgent(
                    CodingAgentConfig(model: resolved.model, cwd: cwd),
                    diagnostics: diagnostics
                )
                let coordinator = SessionCoordinator(
                    agent: agent,
                    modelStore: modelStore,
                    sessionStore: sessionStore,
                    diagnostics: diagnostics
                )
                try? await coordinator.restoreLastSession()
                let transcript = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())
                let tab = TabSession(id: UUID().uuidString, agent: agent, transcript: transcript, coordinator: coordinator)
                tabs = [tab]
                activeTabIndex = 0
                setupSubscriptions(for: tab)
            }
            return
        }

        for (index, id) in meta.tabIDs.enumerated() {
            guard let record = try? sessionStore.load(name: "tab-\(id)") else { continue }
            let agent = await makeCodingAgent(
                CodingAgentConfig(model: resolved.model, cwd: cwd),
                diagnostics: diagnostics
            )
            let coordinator = SessionCoordinator(
                agent: agent,
                modelStore: modelStore,
                sessionStore: sessionStore,
                diagnostics: diagnostics
            )
            try? await coordinator.agent.restoreSession(
                messages: record.messages,
                modelID: record.modelID
            )
            let transcript = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())
            let tab = TabSession(id: id, agent: agent, transcript: transcript, coordinator: coordinator)
            tabs.append(tab)
            setupSubscriptions(for: tab)
            if index == meta.activeIndex {
                activeTabIndex = tabs.count - 1
            }
        }

        if activeTabIndex >= tabs.count {
            activeTabIndex = max(0, tabs.count - 1)
        }
    }

    func createNewTab(workingDirectory: String? = nil) {
        guard let firstTab = tabs.first else { return }
        let workDir = workingDirectory ?? cwd
        let config = CodingAgentConfig(model: firstTab.agent.state.model, cwd: workDir)
        Task {
            let agent = await makeCodingAgent(config, diagnostics: diagnostics)
            let coordinator = SessionCoordinator(
                agent: agent,
                modelStore: modelStore,
                sessionStore: sessionStore,
                diagnostics: diagnostics
            )
            let transcript = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())
            let tab = TabSession(id: UUID().uuidString, agent: agent, transcript: transcript, coordinator: coordinator)
            setupSubscriptions(for: tab)
            tabs.append(tab)
            activeTabIndex = tabs.count - 1
            await diagnostics.log.log(
                level: .info,
                message: "app.tab.created",
                attributes: [
                    "tab_id": .string(tab.id),
                    "tab_count": .int(tabs.count),
                    "cwd": .string(workDir)
                ]
            )
            gitPanel?.setWorkingDirectory(URL(fileURLWithPath: workDir))
            refreshMenuBar()
            render()
        }
    }

    func closeCurrentTab() {
        guard !tabs.isEmpty else { NSApp.terminate(nil); return }
        let tab = tabs[activeTabIndex]
        let closedID = tab.id
        let msgs = tab.agent.state.messages
        if !msgs.isEmpty {
            try? sessionStore.save(name: "tab-\(tab.id)", modelID: tab.agent.state.model.id, messages: msgs)
        }
        tabs.remove(at: activeTabIndex)
        Task {
            await diagnostics.log.log(
                level: .info,
                message: "app.tab.closed",
                attributes: [
                    "tab_id": .string(closedID),
                    "remaining_tabs": .int(tabs.count)
                ]
            )
        }
        if tabs.isEmpty {
            NSApp.terminate(nil)
            return
        }
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        }
        gitPanel?.setWorkingDirectory(URL(fileURLWithPath: activeTab.agent.cwd))
        refreshMenuBar()
        render()
    }

    @objc func tabSelected(_ sender: NSSegmentedControl) {
        activeTabIndex = sender.selectedSegment
        let index = activeTabIndex
        let tabID = activeTab.id
        activeTab.coordinator.markActivitySeen()
        Task {
            await diagnostics.log.log(
                level: .info,
                message: "app.tab.selected",
                attributes: [
                    "tab_index": .int(index),
                    "tab_id": .string(tabID)
                ]
            )
        }
        gitPanel?.setWorkingDirectory(URL(fileURLWithPath: activeTab.agent.cwd))
        refreshMenuBar()
        render()
    }
}
