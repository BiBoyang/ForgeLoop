import Foundation
@testable import ForgeLoopAI

/// Extracts plain text from an assistant message.
public func text(from message: AssistantMessage) -> String {
    message.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }.joined()
}
