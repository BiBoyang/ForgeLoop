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

    /// Four-state activity for ambient surfaces (menu-bar tray). Derived from
    /// the agent's own event stream inside `init` — no polling.
    public private(set) var activity: SessionActivity = .idle
    /// Called on the main actor whenever `activity` changes.
    public var onActivityChange: (@MainActor (SessionActivity) -> Void)?
    private var activityTracker = SessionActivityTracker()
    private var activityUnsubscribe: Unsubscribe?

    /// Task driving the currently active backgrounded run. Set synchronously on
    /// the main actor before `submit` returns, so a follow-up submit that lands
    /// before `agent.state.isStreaming` flips still takes the steer path
    /// (single-active-run invariant, AGENTS.md §4). The task owns the run's
    /// lifetime on the coordinator side (no unstructured `Task.detached`).
    /// internal（非 private）仅供 @testable 测试做确定性同步。
    var activeRunTask: Task<Void, Never>?

    /// Called on the main actor when a backgrounded run fails *before* the
    /// agent's event stream takes over (e.g. a throwing `userPromptSubmit`
    /// hook). Run-time failures don't come through here — `runLifecycle`
    /// already surfaces them via the event stream (failure `messageStart` /
    /// `messageEnd` + `agentEnd`), which frontends render.
    public var onRunStartupFailure: (@MainActor (String) -> Void)?

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
        subscribeActivity()
    }

    /// Feeds the agent's event stream into the activity tracker. The agent
    /// emits from its own task (nonisolated); the hop onto the main actor
    /// happens here, and everything downstream (`activity`, `onActivityChange`)
    /// stays main-actor-isolated.
    private func subscribeActivity() {
        activityUnsubscribe = agent.subscribe { @MainActor [weak self] event, _ in
            guard let self else { return }
            if self.activityTracker.apply(event) {
                let activity = self.activityTracker.activity
                self.activity = activity
                self.onActivityChange?(activity)
            }
        }
    }

    /// The user has seen this session's latest result (window focused on its
    /// tab, or new input submitted): clear `done`/`needsAttention` back to
    /// `idle`.
    public func markActivitySeen() {
        if activityTracker.markSeen() {
            activity = activityTracker.activity
            onActivityChange?(activity)
        }
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
        // submit 本体不再抛 run 错误（run 在后台任务里，错误经事件流/回调暴露），
        // span 只度量提交动作本身；保留 `throws` 签名以兼容现有调用点。
        defer {
            Task {
                await diagnostics.trace.endSpan(span, attributes: [:], error: nil)
            }
        }

        let maskedText = masker.mask(text, preservePrefixLength: 20)
        await diagnostics.log.log(
            level: .debug,
            message: "session.submit.start",
            attributes: [
                "text_preview": .masked(maskedText),
                "is_streaming": .bool(agent.state.isStreaming)
            ]
        )

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("/") {
            return await handleSlashCommand(trimmed)
        }

        let finalText = injectAttachments(into: trimmed, attachments: attachmentStore.snapshot())

        guard !finalText.isEmpty else {
            return .submitted
        }

        if agent.state.isStreaming || activeRunTask != nil {
            agent.steer(.user(UserMessage(text: finalText)))
            return .submitted
        } else {
            // 方案 B（TASK-submit-nonblocking）：后台执行 run，立即返回，
            // TUI/AppKit 事件循环在 run 期间保持响应（审批 picker 可操作、
            // Esc 可中断、后续输入走 steer）。
            // 语义变化：run 错误不再经 throw 上抛——`runLifecycle` 内部已
            // 通过事件流（failure messageStart/messageEnd + agentEnd）暴露，
            // 前端照常渲染；真正的启动失败（见 catch）走 onRunStartupFailure。
            let task = Task { [weak self] in
                guard let self else { return }
                defer { self.activeRunTask = nil }
                do {
                    try await self.agent.prompt(finalText)
                } catch AgentError.alreadyRunning {
                    // 竞态兜底：其他路径（如 agent.continue）抢先启动了 run。
                    // 不静默丢弃用户输入，降级为 steer 汇入进行中的 run。
                    await self.diagnostics.log.log(
                        level: .error,
                        message: "session.submit.run_start_conflict",
                        attributes: ["detail": .string("alreadyRunning; downgraded to steer")]
                    )
                    self.agent.steer(.user(UserMessage(text: finalText)))
                } catch {
                    await self.diagnostics.log.log(
                        level: .error,
                        message: "session.submit.run_start_failed",
                        attributes: ["error": .string("\(error)")]
                    )
                    self.onRunStartupFailure?("\(error)")
                }
            }
            activeRunTask = task
            return .submitted
        }
    }

    /// 仅供 @testable 测试：等待后台 run 完全 settle（含任务清理）。
    /// `activeRunTask` 在 submit 返回前同步置位、run 结束后由任务 defer 清理，
    /// 轮询它是确定性的。生产代码不应依赖此同步。
    func waitForBackgroundRunForTesting() async {
        while activeRunTask != nil {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
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
