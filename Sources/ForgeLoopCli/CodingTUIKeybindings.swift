import Foundation
import ForgeLoopTUI

// MARK: - KeyAction

/// 输入层按键动作抽象，避免 CodingTUI 主循环直接膨胀 KeyEvent 分支。
public enum KeyAction: Sendable, Equatable {
    case insert(Character)
    case delete
    case deleteForward
    case submit
    case insertNewline
    case cancel
    case exit
    case historyPrev
    case historyNext
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case moveToLineStart
    case moveToLineEnd
    case moveToBufferStart
    case moveToBufferEnd
    case killToLineStart
    case killToLineEnd
    case paste(String)
    case newTab
    case closeTab
    case ignore
}

enum EscapeIntent: Sendable, Equatable {
    case abortStreaming
    case killBackgroundTasks
    case clearInput
}

func resolveEscapeIntent(isStreaming: Bool, hasRunningBackgroundTasks: Bool) -> EscapeIntent {
    if isStreaming {
        return .abortStreaming
    }
    if hasRunningBackgroundTasks {
        return .killBackgroundTasks
    }
    return .clearInput
}

public func makeKeybindings() -> KeybindingRegistry<KeyAction> {
    var registry = KeybindingRegistry<KeyAction>()
    func bind(_ sequence: KeySequence, _ action: KeyAction) {
        do {
            try registry.register(sequence, action: action)
        } catch {
            assertionFailure("keybinding registration failed: \(error)")
        }
    }

    bind(KeySequence(KeyStroke(key: .enter)), .insertNewline)
    bind(KeySequence(KeyStroke(key: .backspace)), .delete)
    bind(KeySequence(KeyStroke(key: .delete)), .deleteForward)
    bind(KeySequence(KeyStroke(key: .left)), .moveLeft)
    bind(KeySequence(KeyStroke(key: .right)), .moveRight)
    bind(KeySequence(KeyStroke(key: .up)), .moveUp)
    bind(KeySequence(KeyStroke(key: .down)), .moveDown)
    bind(KeySequence(KeyStroke(key: .home)), .moveToLineStart)
    bind(KeySequence(KeyStroke(key: .end)), .moveToLineEnd)
    bind(KeySequence(KeyStroke(key: .escape)), .cancel)

    // readline-style control-letter bindings (KeyParser emits uppercase letters
    // for Ctrl- combos, so register the uppercase form).
    bind(KeySequence(KeyStroke(key: .character("A"), modifiers: .ctrl)), .moveToLineStart)
    bind(KeySequence(KeyStroke(key: .character("E"), modifiers: .ctrl)), .moveToLineEnd)
    bind(KeySequence(KeyStroke(key: .character("U"), modifiers: .ctrl)), .killToLineStart)
    bind(KeySequence(KeyStroke(key: .character("K"), modifiers: .ctrl)), .killToLineEnd)
    bind(KeySequence(KeyStroke(key: .character("P"), modifiers: .ctrl)), .historyPrev)
    bind(KeySequence(KeyStroke(key: .character("N"), modifiers: .ctrl)), .historyNext)
    bind(KeySequence(KeyStroke(key: .character("O"), modifiers: .ctrl)), .insertNewline)
    bind(KeySequence(KeyStroke(key: .character("J"), modifiers: .ctrl)), .submit)
    bind(KeySequence(KeyStroke(key: .character("C"), modifiers: .ctrl)), .exit)
    bind(KeySequence(KeyStroke(key: .character("T"), modifiers: .command)), .newTab)
    bind(KeySequence(KeyStroke(key: .character("W"), modifiers: .command)), .closeTab)

    return registry
}
