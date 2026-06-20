# Changelog

All notable changes to ForgeLoop will be documented in this file.

## [0.4.0] — 2026-06-19

### Added
- **ForgeLoopDiagnostics** target — unified observability facade with `TraceSystem` + `LogSystem`.
- **Full-stack tracing** across `Provider → SSE → Agent → Tool → Subagent → CLI → AppKit`.
- **Structured logging** with `ConsoleLogSink` (stderr) and `FileLogSink` (JSON Lines, 10 MB rotation, 3 files).
- **Sensitive data masking** for API keys, bearer tokens, and home-directory paths.
- **CLI trace flags** — `--trace-level`, `--trace-file`, plus `FORGELOOP_TRACE_LEVEL` / `FORGELOOP_TRACE_FILE` env vars.
- **AppKit trace toggle** via `UserDefaults` (`ForgeLoopAppTraceEnabled`, `ForgeLoopAppTraceLevel`, `ForgeLoopAppTraceFilePath`).
- **Performance gate CI job** — `PerformanceGateTests` runs as a dedicated, non-blocking job in CI and nightly workflows.
- **SwiftLint** config and CI lint job.

### Changed
- `AgentLoopConfig`, `StreamOptions`, `Agent`, `SessionCoordinator`, `PromptController`, `CodingTUI`, and `AppController` all accept an injected `Diagnostics` instance.
- `PerformanceGateTests` is now skipped in the main `swift test` CI step and run separately to avoid blocking merges on runner noise.

### Fixed
- Multiple span lifecycle bugs in OpenAI/Anthropic/Gemini providers and `FauxProvider`.

## [0.3.0] — 2026-06-18

### Added
- **Security hardening** — `CredentialStore` / `SessionStore` permissions, `PathGuard` symlink resolution, `BashTool` / `ProcessRunner` command-injection defenses.
- **Concurrency fixes** — `SSEParser` made struct, `Agent` mutable state protected by lock, provider `Task.detached` replaced with structured concurrency.
- **Tool fixes** — `EditTool` validation/anchor/backup, `BackgroundTaskManager` resource limits.
- **Test coverage** — cross-provider contract tests (OpenAI responses/chat, Anthropic, Gemini), flaky test fixes.
- **Documentation** — `ARCHITECTURE.md`, `AGENTS.md`, `RELEASE-CHECKLIST.md`, `COLLABORATION.md`, `KIMI.md`.
- **CI split** — `.github/workflows/ci.yml` for PR/push and `.github/workflows/nightly.yml` for scheduled + dispatch runs.

### Changed
- `CodingTUI.swift` split into `CodingTUIStatus`, `CodingTUIKeybindings`, `CodingTUISession` and rendering/input extensions.
- `SessionCoordinator` now shared between CLI and AppKit frontends.
- `ForgeLoopTestSupport` extracted as a common test helper target.

## [0.2.0] — 2026-06-17

### Added
- **AppKit native app** (`ForgeLoopApp` target) with transcript viewer, multi-line input, model picker, and session tabs.
- **Multi-session tabs** via NSSegmentedControl — Cmd+T new tab, Cmd+W close tab, independent Agent per tab, auto-save/restore.
- **Transcript coloring** — user messages (bold blue), assistant (default), tool operations (orange/green/red), thinking (grey italic), code blocks (grey background), comments (green).
- **Slash commands** in AppKit — `/help`, `/save`, `/load`, `/sessions`, `/export [name]` route through shared `SlashCommandRegistry`.
- **Session persistence** — `SessionStore` saves/loads conversation history to `~/.config/forgeloop/sessions/`, auto-save on exit, auto-restore on startup.
- **Keybinding system** — declarative `KeybindingRegistry<KeyAction>` with `KeyResolver` replaces ad-hoc switch; chords and prefix-conflict detection supported.
- **Bg task visualization** — 2s polling, status bar shows running count, dedicated label shows last 3 tasks.
- **Conditional transcript scrolling** — only auto-scrolls when user is near bottom; preserves scroll position when reading history.
- **Input history** — Ctrl+P / Ctrl+N recall previous inputs via `PromptHistory`.
- **Window state memory** — frame position and size restored on relaunch via `UserDefaults`.
- **Markdown export** — `/export [name]` writes conversation to Desktop as `.md` file.
- Tab key inserts 4 spaces in AppKit input.

### Changed
- `CodingTUI` migrated to `MultiLineInputState` for multi-line input editing with soft-wrap-aware viewport navigation.
- `TUI` initialization now uses `liveBudget: 4`, `liveBudgetMode: .physicalRows`, `cursorPositioningMode: .marker` for better CJK IME and streaming output handling.
- Agent event adapter (`toCoreRenderEvent`) returns `[CoreRenderEvent]` array — supports emitting multiple render events per agent event (thinking + text).
- `CoreRenderEvent.blockCancel` used for streaming abort instead of manual notification.
- `CoreRenderEvent.thinking` used for dedicated thinking rendering instead of embedding `💭` prefix in text.
- `renderFrame` and `agent.subscribe` deduplicated — ~100 lines of shared rendering logic removed.
- `AgentEventRenderAdapter` cleaned up — deprecated `toRenderEvent`, `toRenderMessage`, and dead `formatAssistantLines` removed.
- Several internal types made `public` to support AppKit target: `KeyAction`, `makeKeybindings()`, `toCoreRenderEvent()`, `resolveAgentAuth()`, `switchedModel()`, `forgeLoopMarkdownRenderOptions()`, `SlashCommandRegistry`, `PromptController.SubmitResult`.

### Fixed
- `TUIRenderStrategyTests.testInlineEmptyFirstFrameOutputsNothing` — corrected assertion from `""` to `nil` (empty first frame produces no writer output).

### Deprecated
- None.

### Removed
- `KeyEvent.toAction()` extension — replaced by `makeKeybindings()` + `KeyResolver`.
- Local `InputHistory` struct — replaced by `ForgeLoopTUI.PromptHistory`.
- `formatAssistantLines` dead code.

---

## [0.1.2] — 2026-05-11

Initial public release. Terminal-based coding agent with:
- OpenAI ChatCompletions / Responses providers + FauxProvider
- Agent lifecycle with streaming, abort, continue, and steering queue
- TUI with inline retained-mode rendering, Markdown tables, and interaction primitives
- Read, Write, Bash, Edit, Find, Grep, List tools
- Background task execution with status tracking
- Slash commands: `/model`, `/compact`, `/queue`, `/attach`, `/detach`, `/help`, `/exit`
- Login and credential persistence
- Performance baseline gates
