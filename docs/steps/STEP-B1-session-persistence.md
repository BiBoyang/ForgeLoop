## Task: Session Persistence — Save and Restore Conversation History

### Context

You are working on the ForgeLoop project at `/Users/boyang/Desktop/WebKit_build/ForgeLoop`.

ForgeLoop is a macOS coding-agent TUI app. Currently, when you exit the app, all conversation history is lost. This task adds session persistence: auto-save on exit, auto-restore on next launch, and slash commands for manual save/load.

### Key architectural facts

1. **`Message` is already `Codable`** — `Sources/ForgeLoopAI/Messages.swift`, all types (`UserMessage`, `AssistantMessage`, `AssistantBlock`, `ToolCall`, `ToolResultMessage`, `Message`) conform to `Codable`.
2. **`Model` is already `Codable`** — `Sources/ForgeLoopAI/Context.swift`, the struct has `Codable` conformance.
3. **Agent state is accessed via** `agent.state.messages: [Message]` and `agent.state.model: Model` — `Sources/ForgeLoopAgent/AgentState.swift`.
4. **Credentials are stored at** `~/.config/forgeloop/credentials.json` — `Sources/ForgeLoopCli/CredentialStore.swift`. Sessions should use the same directory: `~/.config/forgeloop/sessions/`.
5. **CodingTUI is at** `Sources/ForgeLoopCli/CodingTUI.swift` — the main TUI entry point.
6. **Slash commands are at** `Sources/ForgeLoopCli/SlashCommandRegistry.swift` — registered in `makeDefaultSlashCommandRegistry()`.
7. **ForgeLoop public API is at** `Sources/ForgeLoopCli/ForgeLoop.swift` — the `ForgeLoop.runCodingTUI()` entry point.

### Requirements

#### Step B1.1: Create SessionStore

Create `Sources/ForgeLoopCli/SessionStore.swift`:

```swift
import Foundation
import ForgeLoopAI

struct SessionRecord: Codable {
    var modelID: String
    var messages: [Message]
    var savedAt: Date
    var messageCount: Int
}

struct SessionStore {
    // Directory: ~/.config/forgeloop/sessions/
    // File naming: <name>.json, with "last" as the auto-save name

    func sessionsDirectory() -> URL { ... }
    func save(name: String, modelID: String, messages: [Message]) throws { ... }
    func load(name: String) throws -> SessionRecord { ... }
    func list() throws -> [String]  // returns sorted session names
    func delete(name: String) throws -> Bool { ... }
}
```

Implementation notes:
- Use `FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/forgeloop/sessions")`
- Create directory with intermediate directories if needed
- Use `JSONEncoder` with `.prettyPrinted` for readability
- Use `JSONDecoder` for loading
- `list()` returns `.json` filenames without extension, excluding files starting with `.`
- `delete()` removes the file, returns false if file doesn't exist

#### Step B1.2: Add slash commands

In `Sources/ForgeLoopCli/SlashCommandRegistry.swift`, add these commands to `makeDefaultSlashCommandRegistry()`:

1. **`/save [name]`** — Save current session
   - If no name: save as "last" (auto-save)
   - If name provided: save as that name
   - Access `context.agent.state.messages` and `context.agent.state.model.id`
   - Return `.feedback("Saved session: <name> (<N> messages)")`
   - If streaming: return `.feedback("Cannot save while streaming")`

2. **`/load <name>`** — Load a session
   - Load the session record
   - Set `context.agent.state.messages = record.messages`
   - Switch model if different: `context.agent.state.model = switchedModel(from: current, to: record.modelID)`
   - Also save `context.modelStore`
   - Return `.feedback("Loaded session: <name> (<N> messages)")`
   - If streaming: return `.feedback("Cannot load while streaming")`
   - If no name or file not found: return error feedback

3. **`/sessions`** — List saved sessions
   - List all session names with message counts
   - Return `.feedback(...)` with formatted list

#### Step B1.3: Auto-save on exit

In `Sources/ForgeLoopCli/CodingTUI.swift`, `runCodingTUIInternal()`:

Before the function returns (before `bgMonitor.cancel()` at the end, line 876), add:
```swift
// Auto-save session on exit
let store = SessionStore()
let msgs = agent.state.messages
if !msgs.isEmpty {
    try? store.save(name: "last", modelID: agent.state.model.id, messages: msgs)
}
```

This auto-saves to the "last" slot on every clean exit path. Use `try?` — don't crash on save failure.

Also add auto-save in the `.exit` action handler and in `handleSubmitResult` when result is `.exit`.

#### Step B1.4: Auto-restore on startup

In `Sources/ForgeLoopCli/CodingTUI.swift`, `runCodingTUIInternal()`:

After agent creation (after line 344 `let agent = await makeCodingAgent(...)`), add:

```swift
// Auto-restore last session if it exists
let sessionStore = SessionStore()
if let lastSession = try? sessionStore.load(name: "last"), !lastSession.messages.isEmpty {
    agent.state.messages = lastSession.messages
    if lastSession.modelID != agent.state.model.id {
        agent.state.model = switchedModel(from: agent.state.model, to: lastSession.modelID)
    }
}
```

This restores the last auto-saved session on startup. If no session file exists, silently skip.

#### Step B1.5: Tests

Create `Tests/ForgeLoopCliTests/SessionStoreTests.swift`:

1. `testSaveAndLoadRoundtrip` — save a session with 3 messages, load it, verify message count and content
2. `testListReturnsSavedSessions` — save 2 sessions, list, verify both appear
3. `testDeleteRemovesSession` — save, delete, verify list no longer includes it
4. `testLoadNonExistentReturnsNil` — load a name that doesn't exist
5. `testAutoSaveDoesNotThrowOnEmptyMessages` — save with empty messages array

### DoD

1. `Sources/ForgeLoopCli/SessionStore.swift` created with full implementation
2. `/save`, `/load`, `/sessions` slash commands work
3. Auto-save to "last" on exit (all exit paths)
4. Auto-restore from "last" on startup
5. All existing tests still pass: `swift test --filter SlashCommandsTests`, `swift test --filter CodingTUI`
6. New `SessionStoreTests` all pass
7. `swift build` passes
8. `swift test` full suite passes (except the pre-existing TUIRenderStrategyTests failure)

### Key files to create/modify
- **CREATE**: `Sources/ForgeLoopCli/SessionStore.swift`
- **MODIFY**: `Sources/ForgeLoopCli/SlashCommandRegistry.swift` (add 3 commands)
- **MODIFY**: `Sources/ForgeLoopCli/CodingTUI.swift` (auto-save + auto-restore)
- **CREATE**: `Tests/ForgeLoopCliTests/SessionStoreTests.swift`
