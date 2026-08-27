//
//  GitPanelController+Table.swift
//  ForgeLoop
//
//  Git panel table data source/delegate and cell rendering.
//

import AppKit
import ForgeLoopGit

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension GitPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 22
        case .change: return 20
        case .commit, .worktree: return 34
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let field = makeCell(font: NSFont.systemFont(ofSize: 11, weight: .semibold))
            field.textColor = .secondaryLabelColor
            field.stringValue = title
            return field
        case .change(let change, _):
            let field = makeCell(font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular))
            field.attributedStringValue = changeCellText(change)
            return field
        case .commit(let commit):
            let field = makeCell(font: NSFont.systemFont(ofSize: 11, weight: .regular))
            field.maximumNumberOfLines = 2
            field.attributedStringValue = commitCellText(commit)
            return field
        case .worktree(let worktree):
            let field = makeCell(font: NSFont.systemFont(ofSize: 11, weight: .regular))
            field.maximumNumberOfLines = 2
            field.attributedStringValue = worktreeCellText(worktree)
            return field
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectionChanged()
    }

    // MARK: - Cells

    private func makeCell(font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    private func changeCellText(_ change: GitChange) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: Self.letter(for: change.status) + " ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: Self.color(for: change.status)
        ]))
        result.append(NSAttributedString(string: change.name, attributes: [
            .foregroundColor: change.status == .deleted ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]))
        let directory = (change.path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            result.append(NSAttributedString(string: "  \(directory)", attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor
            ]))
        }
        return result
    }

    private func commitCellText(_ commit: GitCommit) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: commit.shortSHA + "  ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.systemBlue
        ]))
        result.append(NSAttributedString(string: commit.subject, attributes: [
            .foregroundColor: NSColor.labelColor
        ]))
        let relative = Self.dateFormatter.localizedString(for: commit.date, relativeTo: Date())
        result.append(NSAttributedString(string: "\n\(commit.author) · \(relative)", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        return result
    }

    /// The single-letter badge for a change kind, colored after GitHub Desktop.
    private static func letter(for status: GitFileStatus) -> String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .conflicted: return "!"
        case .untracked: return "U"
        }
    }

    private static func color(for status: GitFileStatus) -> NSColor {
        switch status {
        case .modified: return .systemBlue
        case .added, .untracked: return .systemGreen
        case .deleted: return .systemRed
        case .renamed, .copied: return .systemOrange
        case .conflicted: return .systemYellow
        }
    }
}
