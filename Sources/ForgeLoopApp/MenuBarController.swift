//
//  MenuBarController.swift
//  ForgeLoop
//
//  Menu-bar tray: one status item aggregating all tab sessions, inspired by
//  termio's MenuBarController (MIT): https://github.com/termio-sh/termio
//  — flat monochrome glyph that breathes while any agent works and wears a
//  coloured badge for done/needsAttention, plus a roster menu where each row
//  is one tab and picking it focuses that tab's window.
//

import AppKit
import ForgeLoopCli

/// One row in the tray roster: a tab's identity plus its current activity.
struct TraySessionRow: Equatable {
    let id: String
    let title: String
    let detail: String
    let activity: SessionActivity
    let isActive: Bool
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onSelect: (String) -> Void
    private let onToggleWindow: () -> Void

    private var rows: [TraySessionRow] = []
    private var windowVisible = true
    private var isMenuOpen = false

    init(onSelect: @escaping (String) -> Void, onToggleWindow: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onToggleWindow = onToggleWindow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.wantsLayer = true
        refresh()
    }

    /// Pushes the latest session snapshot. Cheap: rebuilds icon and (when the
    /// menu is closed) the menu. Call on every activity/tab change.
    func update(rows: [TraySessionRow], windowVisible: Bool) {
        self.rows = rows
        self.windowVisible = windowVisible
        refresh()
    }

    private func refresh() {
        applyIcon(for: aggregateSessionActivity(rows.map(\.activity)))
        // Rebuilding the menu while it's open swaps the items under the user's
        // cursor (and can dismiss it); `menuDidClose` catches up instead.
        guard !isMenuOpen else { return }
        statusItem.menu = buildMenu()
    }

    // MARK: - Icon

    private enum Badge {
        case done, attention
        var color: NSColor {
            switch self {
            case .done: return .systemGreen
            case .attention: return .systemOrange
            }
        }
    }

    private func applyIcon(for activity: SessionActivity) {
        guard let button = statusItem.button else { return }
        button.layer?.removeAnimation(forKey: Self.workingPulseKey)
        switch activity {
        case .idle:
            button.image = Self.ringIcon(badge: nil)
        case .working:
            button.image = Self.ringIcon(badge: nil)
            addWorkingPulse(to: button)
        case .done:
            button.image = Self.ringIcon(badge: .done)
        case .needsAttention:
            button.image = Self.ringIcon(badge: .attention)
        }
    }

    /// ForgeLoop's tray glyph: a simple ring (the "loop"), drawn flat. Without
    /// a badge it's a template image so the system tints it for the current
    /// appearance; a badge forces a coloured composite with the dot tucked
    /// into the top-right, cleared around by a transparent moat.
    private static func ringIcon(badge: Badge?) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let inset: CGFloat = 2
            let ringRect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 2.4
            (badge == nil ? NSColor.black : NSColor.labelColor).setStroke()
            ring.stroke()

            if let badge {
                let diameter: CGFloat = 7
                let dot = NSRect(
                    x: side - diameter - inset, y: side - diameter - inset,
                    width: diameter, height: diameter
                )
                let context = NSGraphicsContext.current
                context?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
                context?.compositingOperation = .sourceOver
                badge.color.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = badge == nil
        return image
    }

    private static let workingPulseKey = "working"

    /// Breathes the glyph's opacity while any session works. Layer animation is
    /// the reliable way to animate a status button's image (SF Symbol effects
    /// don't apply to custom images).
    private func addWorkingPulse(to button: NSStatusBarButton) {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(pulse, forKey: Self.workingPulseKey)
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        // Roster reads top-down as a to-do list: the states that want the user
        // (attention, then unseen results) rise above live work and idle tabs.
        let sorted = rows.sorted { rosterPriority($0.activity) < rosterPriority($1.activity) }
        for row in sorted {
            let item = NSMenuItem(title: "", action: #selector(didPickSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
            item.attributedTitle = Self.rowTitle(row)
            item.image = Self.statusDot(row.activity)
            if row.isActive {
                item.state = .on
            }
            menu.addItem(item)
        }

        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        let toggle = NSMenuItem(
            title: windowVisible ? "Hide Window" : "Show Window",
            action: #selector(didToggleWindow(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        let quit = NSMenuItem(title: "Quit ForgeLoop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// Ordering weight mirroring `aggregateSessionActivity`'s worst-first rule.
    private func rosterPriority(_ activity: SessionActivity) -> Int {
        switch activity {
        case .needsAttention: return 0
        case .done: return 1
        case .working: return 2
        case .idle: return 3
        }
    }

    private static func rowTitle(_ row: TraySessionRow) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: row.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]))
        if !row.detail.isEmpty {
            result.append(NSAttributedString(string: "  \(row.detail)", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        return result
    }

    /// Coloured dot per state, matching the tab-status palette: green = done,
    /// orange = needs you, accent = working, none for idle (at rest, seen).
    private static func statusDot(_ activity: SessionActivity) -> NSImage? {
        let color: NSColor
        switch activity {
        case .needsAttention: color = .systemOrange
        case .done: color = .systemGreen
        case .working: color = .controlAccentColor
        case .idle: return nil
        }
        let side: CGFloat = 9
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1)).fill()
            return true
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        // Catch up on changes deferred while the menu was open.
        refresh()
    }

    // MARK: - Actions

    @objc private func didPickSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelect(id)
    }

    @objc private func didToggleWindow(_ sender: NSMenuItem) {
        onToggleWindow()
    }
}
