import Foundation
@testable import ForgeLoopAI

/// Builds a stream that emits a single assistant message and ends.
public func makeStream(_ message: AssistantMessage) -> AssistantMessageStream {
    let stream = AssistantMessageStream()
    Task {
        stream.push(.start(partial: message))
        for (index, block) in message.content.enumerated() {
            switch block {
            case .text(let textContent):
                stream.push(.textStart(contentIndex: index, partial: message))
                stream.push(.textDelta(contentIndex: index, delta: textContent.text, partial: message))
                stream.push(.textEnd(contentIndex: index, content: textContent.text, partial: message))
            default:
                break
            }
        }
        stream.push(.done(reason: message.stopReason, message: message))
        stream.end(message)
    }
    return stream
}
