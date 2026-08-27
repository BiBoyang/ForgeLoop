//
//  AppController+Updates.swift
//  ForgeLoop
//
//  Sparkle auto-update wiring: the standard SPUStandardUpdaterController plus
//  a minimal main menu carrying "Check for Updates…". The feed URL and EdDSA
//  public key live in the bundle's Info.plist (SUFeedURL / SUPublicEDKey) —
//  nothing update-related is hardcoded here.
//

import AppKit
import Sparkle

extension AppController {
    /// Standard Sparkle controller; starts the updater immediately so
    /// scheduled background checks work without user action. Only started when
    /// running from a packaged .app (SUFeedURL present) — a bare `swift run`
    /// binary has no bundle, and Sparkle cannot check anything there.
    func setupUpdater() {
        installMainMenu()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        updateMenuItem?.target = controller
        updateMenuItem?.isEnabled = true
    }

    /// The app ships no storyboard, so the main menu is built in code: an app
    /// menu with About / Check for Updates… / Quit, and an Edit menu so
    /// copy-paste shortcuts work in the transcript and input views.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ForgeLoop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        // Enabled once the updater exists (packaged build only).
        updateItem.isEnabled = false
        appMenu.addItem(updateItem)
        updateMenuItem = updateItem
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit ForgeLoop",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
