import AppKit
import ForgeLoopCli

// MARK: - Menu bar tray

extension AppController {
    /// Installs the tray and wires it to the tab list. Called once after the
    /// window exists; subsequent state arrives via `refreshMenuBar()`.
    func setupMenuBar() {
        let controller = MenuBarController(
            onSelect: { [weak self] id in self?.activateTab(id: id) },
            onToggleWindow: { [weak self] in self?.toggleWindowVisibility() }
        )
        menuBar = controller
        for tab in tabs {
            observeActivity(of: tab)
        }
        refreshMenuBar()
    }

    /// Hooks one tab's coordinator so activity changes reach the tray.
    /// Called for every tab created after `setupMenuBar()` too.
    func observeActivity(of tab: TabSession) {
        tab.coordinator.onActivityChange = { [weak self] _ in
            self?.refreshMenuBar()
        }
    }

    func refreshMenuBar() {
        let rows = tabs.indices.map { index in
            let tab = tabs[index]
            return TraySessionRow(
                id: tab.id,
                title: menuBarTitle(for: tab, index: index),
                detail: URL(fileURLWithPath: tab.agent.cwd).lastPathComponent,
                activity: tab.coordinator.activity,
                isActive: index == activeTabIndex
            )
        }
        menuBar?.update(rows: rows, windowVisible: window?.isVisible ?? false)
    }

    /// Same labelling rule as the tab selector: tabs on the launch directory
    /// are "Session N", others (worktrees) use the directory name.
    private func menuBarTitle(for tab: TabSession, index: Int) -> String {
        if tab.agent.cwd == cwd {
            return "Session \(index + 1)"
        }
        return URL(fileURLWithPath: tab.agent.cwd).lastPathComponent
    }

    /// Tray roster pick: bring the window forward, select the tab, and mark
    /// its result seen (the user is now looking at it).
    private func activateTab(id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        activeTabIndex = index
        tabs[index].coordinator.markActivitySeen()
        showWindow()
        gitPanel?.setWorkingDirectory(URL(fileURLWithPath: activeTab.agent.cwd))
        render()
    }

    private func toggleWindowVisibility() {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            showWindow()
        }
        refreshMenuBar()
    }

    private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Focusing the window means the user is looking at the active tab — its
    /// done/needsAttention state has been seen.
    func windowDidBecomeKey(_ notification: Notification) {
        guard !tabs.isEmpty else { return }
        activeTab.coordinator.markActivitySeen()
        refreshMenuBar()
    }
}
