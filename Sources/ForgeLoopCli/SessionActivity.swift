import Foundation
import ForgeLoopAI
import ForgeLoopAgent

/// High-level activity of one agent session, distilled from `AgentEvent`s for
/// surfaces that can't watch the transcript (menu-bar tray, dock badge).
///
/// The mapping is deliberately small:
/// - `working`: a run is in flight (`.agentStart` arrived, `.agentEnd` has not).
/// - `done`: the last run finished cleanly and the user hasn't looked yet.
/// - `needsAttention`: the last run ended with an error. ForgeLoop's tools
///   never pause for confirmation (e.g. `PathGuard` rejects outright), so
///   there is no "waiting on user input" mid-run state — an erroring run is
///   the only situation where the agent stops and the user must intervene.
/// - `idle`: nothing running, nothing unseen. Also the result of a user-aborted
///   run — the user already knows, no badge needed.
public enum SessionActivity: Sendable, Equatable {
    case idle
    case working
    case done
    case needsAttention
}

/// Stateful per-session reducer: feed it `AgentEvent`s, read `activity`.
/// Value type, no isolation requirements — the owner decides the actor.
public struct SessionActivityTracker: Sendable, Equatable {
    public private(set) var activity: SessionActivity = .idle

    public init() {}

    /// Folds one agent event into the activity. Returns true when it changed.
    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> Bool {
        let next: SessionActivity
        switch event {
        case .agentStart:
            next = .working
        case .agentEnd(let messages):
            next = Self.restingState(after: messages)
        default:
            return false
        }
        guard next != activity else { return false }
        activity = next
        return true
    }

    /// Clears the "unseen" resting states once the user has looked at the
    /// session (window focused on this tab, or new input submitted). A working
    /// session is untouched — it's live progress, not a notification.
    @discardableResult
    public mutating func markSeen() -> Bool {
        switch activity {
        case .done, .needsAttention:
            activity = .idle
            return true
        case .idle, .working:
            return false
        }
    }

    private static func restingState(after messages: [Message]) -> SessionActivity {
        guard case .assistant(let last) = messages.last else { return .done }
        switch last.stopReason {
        case .error: return .needsAttention
        case .aborted: return .idle
        default: return .done
        }
    }
}

/// Worst-first aggregate across sessions: what the tray icon should show.
/// `needsAttention` outranks everything (user must act), then unseen results,
/// then live work; idle only when every session is at rest and seen.
public func aggregateSessionActivity(_ activities: [SessionActivity]) -> SessionActivity {
    if activities.contains(.needsAttention) { return .needsAttention }
    if activities.contains(.done) { return .done }
    if activities.contains(.working) { return .working }
    return .idle
}
