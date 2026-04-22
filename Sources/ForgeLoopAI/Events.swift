import Foundation

public enum AssistantMessageEvent: Sendable, Hashable {
    case start(partial: AssistantMessage)
    case textStart(contentIndex: Int, partial: AssistantMessage)
    case textDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case textEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case done(reason: StopReason, message: AssistantMessage)
    case error(reason: StopReason, error: AssistantMessage)
}
