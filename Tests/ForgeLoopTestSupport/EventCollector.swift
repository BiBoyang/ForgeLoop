import Foundation
@testable import ForgeLoopAgent

/// Thread-safe event collector for AgentEvent-based tests.
public actor EventCollector {
    public private(set) var events: [AgentEvent] = []

    public init() {}

    public func append(_ event: AgentEvent) {
        events.append(event)
    }

    public func all() -> [AgentEvent] {
        events
    }

    public func clear() {
        events.removeAll()
    }
}
