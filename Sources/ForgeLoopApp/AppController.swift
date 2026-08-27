import AppKit
import Foundation
import ForgeLoopAI
import ForgeLoopAgent
import ForgeLoopCli
import ForgeLoopDiagnostics
import ForgeLoopTUI
import Sparkle

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    let eventAdapter = AppKitEventAdapter()
    let keyResolver = KeyResolver<KeyAction>(registry: makeKeybindings())
    let sessionStore = SessionStore()
    let modelStore = ModelStore()
    let diagnostics: Diagnostics

    var window: NSWindow?
    var titleLabel: NSTextField?
    var statusLabel: NSTextField?
    var transcriptView: NSTextView?
    var inputView: NSTextView?
    var keyHintLabel: NSTextField?
    var keyMonitor: Any?

    var modelPicker: NSPopUpButton?
    var modelPickerIDs: [String] = []
    var tabSelector: NSSegmentedControl?

    private let slashRegistry = makeDefaultSlashCommandRegistry()
    var bgTaskLabel: NSTextField?

    /// The git side panel; populated by `setupWindow()`.
    var gitPanel: GitPanelController?

    /// The menu-bar tray; populated by `setupMenuBar()`.
    var menuBar: MenuBarController?

    /// Sparkle's updater; populated by `setupUpdater()`.
    var updaterController: SPUStandardUpdaterController?

    /// "Check for Updates…" item; enabled once the updater exists.
    var updateMenuItem: NSMenuItem?

    var tabs: [TabSession] = []
    var activeTabIndex: Int = 0
    var activeTab: TabSession {
        tabs[activeTabIndex]
    }

    let cwd = FileManager.default.currentDirectoryPath

    override init() {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: "ForgeLoopAppTraceEnabled")
        if enabled {
            let fileURL = defaults.url(forKey: "ForgeLoopAppTraceFilePath")
                ?? defaults.string(forKey: "ForgeLoopAppTraceFilePath").map { URL(fileURLWithPath: $0) }
                ?? Self.defaultTraceFileURL()
            let levelString = defaults.string(forKey: "ForgeLoopAppTraceLevel") ?? "debug"
            let level: TraceLevel
            switch levelString.lowercased() {
            case "info": level = .info
            case "warn", "warning": level = .warn
            case "error": level = .error
            default: level = .debug
            }
            let log = FileLogSink(fileURL: fileURL)
            diagnostics = Diagnostics(
                trace: LoggingTraceSystem(log: AppLevelFilteringLogSink(minimumLevel: level, sink: log)),
                log: AppLevelFilteringLogSink(minimumLevel: level, sink: log)
            )
        } else {
            diagnostics = Diagnostics()
        }
        super.init()
    }

    private static func defaultTraceFileURL() -> URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/forgeloop-trace.jsonl")
        ?? URL(fileURLWithPath: "/tmp/forgeloop-trace.jsonl")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await diagnostics.log.log(
                level: .info,
                message: "app.launch",
                attributes: [
                    "trace_enabled": .bool(UserDefaults.standard.bool(forKey: "ForgeLoopAppTraceEnabled"))
                ]
            )
        }

        setupWindow()
        setupMenuBar()
        setupUpdater()
        installKeyMonitor()
        updateViewportWidth()

        Task {
            do {
                let resolved = try await resolveAgentAuth()

                // Restore tabs from tab-meta.json if present; otherwise create a single tab.
                await restoreTabs(resolved: resolved)

                if tabs.isEmpty {
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
                    let transcript = TranscriptRenderer(markdownOptions: forgeLoopMarkdownRenderOptions())
                    let tab = TabSession(id: UUID().uuidString, agent: agent, transcript: transcript, coordinator: coordinator)
                    tabs = [tab]
                    activeTabIndex = 0
                    setupSubscriptions(for: tab)
                }

                self.populateModelPicker()
                self.refreshMenuBar()

                Task { @MainActor [weak self] in
                    while true {
                        try? await Task.sleep(for: .seconds(2))
                        guard let self, let manager = self.activeTab.agent.backgroundTaskManager else { continue }
                        let tasks = await manager.status()
                        self.activeTab.bgTaskLines = tasks.map { record in
                            let symbol: String
                            switch record.status {
                            case .running: symbol = "◉"
                            case .success: symbol = "✓"
                            case .failed: symbol = "✗"
                            case .cancelled: symbol = "⊘"
                            }
                            let command = record.command.count > 40
                                ? String(record.command.prefix(40)) + "..."
                                : record.command
                            return "\(symbol) [\(record.id)] \(command)"
                        }
                        self.render()
                    }
                }

                self.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.render()
            } catch {
                await showErrorAndQuit(error)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await diagnostics.log.log(
                level: .info,
                message: "app.terminate",
                attributes: ["tab_count": .int(tabs.count)]
            )
        }
        removeKeyMonitor()
    }

    func windowWillClose(_ notification: Notification) {
        Task {
            await diagnostics.log.log(
                level: .info,
                message: "app.window.close",
                attributes: ["tab_count": .int(tabs.count)]
            )
        }

        if let window {
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "ForgeLoopWindowFrame")
        }

        for tab in tabs {
            let msgs = tab.agent.state.messages
            if !msgs.isEmpty {
                try? sessionStore.save(name: "tab-\(tab.id)", modelID: tab.agent.state.model.id, messages: msgs)
            }
        }

        let tabIDs = tabs.map(\.id)
        let meta = TabMeta(tabIDs: tabIDs, activeIndex: activeTabIndex)
        if let metaData = try? JSONEncoder().encode(meta) {
            let metaURL = sessionStore.sessionsDirectory().appendingPathComponent("tab-meta.json")
            try? metaData.write(to: metaURL)
        }

        NSApp.terminate(nil)
    }

    func windowDidResize(_ notification: Notification) {
        updateViewportWidth()
        render()
    }

    // MARK: - Errors

    func showErrorAndQuit(_ error: Error) async {
        let alert = NSAlert()
        alert.messageText = "ForgeLoop failed to start"
        alert.informativeText = "\(error)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                alert.runModal()
                continuation.resume()
            }
        }
        NSApp.terminate(nil)
    }
}

struct TabMeta: Codable {
    var tabIDs: [String]
    var activeIndex: Int
}

private struct AppLevelFilteringLogSink: LogSystem {
    private let minimumLevel: TraceLevel
    private let sink: LogSystem

    init(minimumLevel: TraceLevel, sink: LogSystem) {
        self.minimumLevel = minimumLevel
        self.sink = sink
    }

    func log(
        level: TraceLevel,
        message: String,
        attributes: [String: TraceAttribute]
    ) async {
        guard levelOrder(level) >= levelOrder(minimumLevel) else { return }
        await sink.log(level: level, message: message, attributes: attributes)
    }

    private func levelOrder(_ level: TraceLevel) -> Int {
        switch level {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }
}
