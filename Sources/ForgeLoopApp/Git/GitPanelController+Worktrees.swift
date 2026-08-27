//
//  GitPanelController+Worktrees.swift
//  ForgeLoop
//
//  Git panel worktree list UI and actions (create/open/remove).
//

import AppKit
import ForgeLoopGit
import ObjectiveC

extension GitPanelController {
    func worktreeCellText(_ worktree: Worktree) -> NSAttributedString {
        let line1 = NSMutableAttributedString()
        let branchTitle = worktree.branch ?? "detached HEAD"
        line1.append(NSAttributedString(string: branchTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]))
        if worktree.isPrimary {
            line1.append(NSAttributedString(string: " (primary)", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        let line2 = NSAttributedString(string: "\n\(worktree.path)", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        line1.append(line2)
        return line1
    }

    @objc func newWorktreePressed(_ sender: NSButton) {
        guard let repoRoot else { return }
        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.informativeText = "Creates a new branch checked out in its own directory."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let branchField = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 22))
        branchField.placeholderString = "branch name"
        let pathField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        pathField.placeholderString = "worktree path"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        container.addSubview(branchField)
        container.addSubview(pathField)
        alert.accessoryView = container

        pathField.stringValue = defaultWorktreePath(branch: "branch", repoRoot: repoRoot)
        // NSTextField.delegate is weak; pin the suggestor to the field itself.
        let suggestor = WorktreePathSuggestor { [weak pathField, weak self] name in
            guard let self, let repoRoot = self.repoRoot else { return }
            pathField?.stringValue = self.defaultWorktreePath(branch: name, repoRoot: repoRoot)
        }
        branchField.delegate = suggestor
        objc_setAssociatedObject(branchField, &WorktreePathSuggestor.key, suggestor, .OBJC_ASSOCIATION_RETAIN)
        alert.window.initialFirstResponder = branchField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let rawBranch = branchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawBranch.isEmpty else { return }
        let branch = WorktreeService.sanitizedName(rawBranch)
        let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPath = path.isEmpty ? defaultWorktreePath(branch: branch, repoRoot: repoRoot) : path
        createWorktree(branch: branch, path: targetPath)
    }

    func defaultWorktreePath(branch: String, repoRoot: URL) -> String {
        let name = WorktreeService.sanitizedName(branch)
        return repoRoot
            .deletingLastPathComponent()
            .appendingPathComponent("\(repoRoot.lastPathComponent)-worktrees")
            .appendingPathComponent(name)
            .path
    }

    private func createWorktree(branch: String, path: String) {
        guard let service = worktreeService else { return }
        let url = URL(fileURLWithPath: path)
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            defer { self.setBusy(false) }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try await service.add(at: url, branch: branch)
                refresh()
                onOpenSession?(url.path)
            } catch {
                showGitError(error, title: "Failed to Create Worktree")
            }
        }
    }

    @objc func openSessionPressed(_ sender: NSButton) {
        guard let worktree = selectedWorktree else { return }
        onOpenSession?(worktree.path)
    }

    @objc func removeWorktreePressed(_ sender: NSButton) {
        guard let worktree = selectedWorktree else { return }
        removeWorktree(worktree)
    }

    @objc func contextOpenSession(_ sender: NSMenuItem) {
        guard let worktree = sender.representedObject as? Worktree else { return }
        onOpenSession?(worktree.path)
    }

    @objc func contextRemoveWorktree(_ sender: NSMenuItem) {
        guard let worktree = sender.representedObject as? Worktree else { return }
        removeWorktree(worktree)
    }

    func contextMenu(forRowAt row: Int) -> NSMenu? {
        guard rows.indices.contains(row), case .worktree(let worktree) = rows[row] else { return nil }
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "Open Session",
            action: #selector(contextOpenSession(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.representedObject = worktree
        menu.addItem(openItem)
        if !worktree.isPrimary {
            let removeItem = NSMenuItem(
                title: "Remove Worktree…",
                action: #selector(contextRemoveWorktree(_:)),
                keyEquivalent: ""
            )
            removeItem.target = self
            removeItem.representedObject = worktree
            menu.addItem(removeItem)
        }
        return menu
    }

    private func removeWorktree(_ worktree: Worktree) {
        guard !worktree.isPrimary, let service = worktreeService else { return }
        Task { [weak self] in
            guard let self else { return }
            let dirty = await self.isWorktreeDirty(worktree)
            if dirty {
                let confirmed = self.confirmDirtyRemoval(worktree)
                guard confirmed else { return }
            }
            await self.performRemove(worktree, force: dirty, service: service)
        }
    }

    /// A worktree we cannot stat is treated as dirty so removal always asks.
    private func isWorktreeDirty(_ worktree: Worktree) async -> Bool {
        let probe = GitService(repository: URL(fileURLWithPath: worktree.path))
        do {
            let status = try await probe.status()
            return !status.staged.isEmpty || !status.unstaged.isEmpty || !status.untracked.isEmpty
        } catch {
            return true
        }
    }

    private func confirmDirtyRemoval(_ worktree: Worktree) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Worktree Has Uncommitted Changes"
        alert.informativeText = "\(worktree.path) contains uncommitted changes. Remove it anyway? This cannot be undone."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func performRemove(_ worktree: Worktree, force: Bool, service: WorktreeService) async {
        setBusy(true)
        defer { setBusy(false) }
        do {
            try await service.remove(at: URL(fileURLWithPath: worktree.path), force: force)
            refresh()
        } catch {
            showGitError(error, title: "Failed to Remove Worktree")
        }
    }

    private func setBusy(_ busy: Bool) {
        tableView?.isEnabled = !busy
        newWorktreeButton?.isEnabled = !busy
        updateWorktreeControls()
    }

    private func showGitError(_ error: Error, title: String) {
        let detail: String
        if let gitError = error as? GitError {
            detail = gitError.errorDescription ?? error.localizedDescription
        } else {
            detail = error.localizedDescription
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Updates the suggested worktree path live as the branch name is edited.
private final class WorktreePathSuggestor: NSObject, NSTextFieldDelegate {
    /// Association key for pinning the suggestor to its text field; main-thread
    /// only, guarded by the alert's modal lifetime.
    nonisolated(unsafe) static var key = 0
    private let update: (String) -> Void

    init(update: @escaping (String) -> Void) {
        self.update = update
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        update(field.stringValue)
    }
}

/// NSTableView subclass that supports per-row context menus.
final class WorktreeTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        return menuProvider?(row)
    }
}
