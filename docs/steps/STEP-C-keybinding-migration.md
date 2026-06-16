## Task: Migrate ForgeLoop from ad-hoc KeyEvent.toAction() to KeybindingRegistry + KeyResolver

### Context

You are working on the ForgeLoop project at `/Users/boyang/Desktop/WebKit_build/ForgeLoop`.

ForgeLoop is a macOS coding-agent TUI app. It currently uses a manual `KeyEvent.toAction()` switch statement in `Sources/ForgeLoopCli/CodingTUI.swift` to map key events to actions. ForgeLoopTUI (the sibling library at `../ForgeLoopTUI`) ships a declarative keybinding system (`KeybindingRegistry`, `KeyResolver`, `KeyStroke`, `KeySequence`) that supports chords, prefix-conflict detection, and timeout-based chord resolution. This task migrates ForgeLoop from the ad-hoc switch to the library's keybinding system.

### Reference implementation

The MinimalAIApp example already uses this system end-to-end. Study these files:
- `/Users/boyang/Desktop/WebKit_build/ForgeLoopTUI/Examples/MinimalAIApp/Sources/MinimalAIApp/main.swift` — lines 74-91 (AppCommand enum), 108 (resolver init), 138-179 (keybindings factory), 298-376 (event processing loop with feed/tick)
- `/Users/boyang/Desktop/WebKit_build/ForgeLoopTUI/Sources/ForgeLoopTUI/Input/KeyBinding.swift` — `KeyStroke`, `KeySequence`, `KeyBinding`, `KeybindingRegistry`
- `/Users/boyang/Desktop/WebKit_build/ForgeLoopTUI/Sources/ForgeLoopTUI/Input/KeyResolver.swift` — `KeyResolver<Action>`, `ResolvedKey<Action>`

### Current state (what to change)

File: `Sources/ForgeLoopCli/CodingTUI.swift`

1. `KeyAction` enum (lines 219-241): Keep this — it's the action vocabulary.
2. `KeyEvent.toAction()` extension (lines 259-315): This switch MUST be replaced with a `KeybindingRegistry<KeyAction>`.
3. Main event loop (lines 636-873): Currently calls `event.toAction()` and switches on `KeyAction`. Must be changed to feed events through `KeyResolver<KeyAction>` and handle `ResolvedKey<KeyAction>`.
4. The run loop (around line 416-419 in the MinimalAIApp equivalent): Must call `resolver.tick()` periodically for chord timeout.

### Requirements

#### Step C1: Create keybinding factory function

In `CodingTUI.swift`, add a function (similar to MinimalAIApp's `defaultKeybindings()`):

```swift
func makeKeybindings() -> KeybindingRegistry<KeyAction> {
    var registry = KeybindingRegistry<KeyAction>()
    // Register each binding using try? registry.register(KeySequence(KeyStroke(...)), action: ...)
    // Map EVERY entry from the old toAction() switch:
    // - Ctrl+C → .exit
    // - Ctrl+A → .moveToLineStart
    // - Ctrl+E → .moveToLineEnd
    // - Ctrl+U → .killToLineStart
    // - Ctrl+K → .killToLineEnd
    // - Ctrl+P → .historyPrev
    // - Ctrl+N → .historyNext
    // - Ctrl+O → .insertNewline
    // - Ctrl+J → .submit
    // - Backspace → .delete
    // - Delete → .deleteForward
    // - Enter → .insertNewline
    // - Escape → .cancel
    // - Up → .moveUp
    // - Down → .moveDown
    // - Left → .moveLeft
    // - Right → .moveRight
    // - Home → .moveToLineStart
    // - End → .moveToLineEnd
    // Note: plain unbound characters are NOT registered — they fall through as .passthrough
    return registry
}
```

IMPORTANT: `KeyParser` emits Ctrl-letter combos with uppercase characters (e.g., `Ctrl-a` → `.character("A"), .ctrl`). Register the UPPERCASE form.

Paste events (`.paste`) MUST NOT be registered — they always pass through `KeyResolver` automatically.

#### Step C2: Add KeyResolver to runCodingTUIInternal

In `runCodingTUIInternal()`, add after the other state variables:

```swift
let keyResolver = KeyResolver(registry: makeKeybindings())
```

NOTE: `KeyResolver` is **non-Sendable**. Since `runCodingTUIInternal` is `@MainActor`, all calls will be on MainActor — this is safe. Use `let` (not `var`) — the resolver manages its own mutable state internally.

#### Step C3: Replace event dispatch loop

Current pattern (lines 636-873):
```swift
for await event in keyEvents {
    let action = event.toAction()
    // picker dispatch...
    switch action {
    case .insert(let c): ...
    case .delete: ...
    // etc
    }
}
```

New pattern:
```swift
for await event in keyEvents {
    for resolved in keyResolver.feed(event) {
        let handled = handleResolvedKey(resolved)
        if !handled { return }
    }
}
```

Create a `handleResolvedKey(_ resolved: ResolvedKey<KeyAction>) -> Bool` function (can be a local function inside runCodingTUIInternal) that:

1. For `.action(let keyAction)`: apply the action using the EXISTING switch logic (copy-paste from current dispatch, don't rewrite). Return false for `.exit`.
2. For `.passthrough(let event)`: if it's a plain character with no modifiers → `.insert(c)`. If it's paste → `.insertText(text)`. Otherwise ignore.

The picker navigation logic (lines 639-679) must still work: when `activeModelPicker` is non-nil, arrow keys/Enter/Esc should control the picker, not the input. Integrate this into `handleResolvedKey`.

#### Step C4: Add resolver.tick() to run loop

In the main run loop (the `while reader.running && !exitFlag.value` equivalent — ForgeLoop uses `for await event in keyEvents`), after processing events from the stream, call:

```swift
for resolved in keyResolver.tick() {
    if !handleResolvedKey(resolved) { return }
}
```

Since ForgeLoop's main loop is `for await event in keyEvents` (which blocks waiting for input), the tick should be called AFTER processing each event batch. Add it right after the `for resolved in keyResolver.feed(event)` loop, before the next iteration.

Actually, looking at ForgeLoop's architecture more carefully: it uses `InputReader` which dispatches on a background queue, then yields events via `AsyncStream`. The `for await` loop suspends between events. The `tick()` must be called even when no new events arrive (for chord timeout). The MinimalAIApp uses `RunLoop.current.run(mode:before:)` with a 100ms timeout and calls `tick()` in each iteration.

But ForgeLoop doesn't have such a run loop — it uses `for await`. The simplest approach: replace the `for await` with a pattern that allows periodic tick. However, this changes the architecture significantly. 

**Simpler alternative**: add tick calls inside the `for await` loop right after processing each batch. Chords that time out while waiting for the next event will flush when the next event arrives. This is not perfect (a lone Ctrl-X would hang until the next keypress) but is acceptable for now since ForgeLoop currently has no multi-key chords registered.

#### Step C5: Remove old toAction() extension

Delete the `extension KeyEvent { func toAction() -> KeyAction { ... } }` block (lines 259-315 in the current file).

#### Step C6: Update tests

Check `Tests/ForgeLoopCliTests/CodingTUIStatusTests.swift` and `Tests/ForgeLoopCliTests/CodingTUIEscapeIntentTests.swift` for any tests that depend on `KeyEvent.toAction()`. If any tests construct `KeyEvent` and call `.toAction()`, update them to use `KeyResolver.feed()` instead.

### DoD
1. `KeyEvent.toAction()` extension is REMOVED
2. `makeKeybindings()` function exists and registers ALL current key mappings
3. `keyResolver` is instantiated in `runCodingTUIInternal`
4. Event dispatch loop uses `keyResolver.feed(event)` + `ResolvedKey` pattern
5. Picker navigation (↑↓ Enter Esc in picker mode) still works
6. Ctrl-J submits, Enter inserts newline (idle) / submits (streaming) — EXISTING behavior preserved
7. `swift build` passes
8. `swift test --filter CodingTUI` all pass
9. `swift test --filter ScreenLayoutIntegrationTests` all pass
10. No new warnings

### Key files
- `Sources/ForgeLoopCli/CodingTUI.swift` — primary modification target
- `Tests/ForgeLoopCliTests/CodingTUIStatusTests.swift` — may need updates
- `Tests/ForgeLoopCliTests/CodingTUIEscapeIntentTests.swift` — may need updates
