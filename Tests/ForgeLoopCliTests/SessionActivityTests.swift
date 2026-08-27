import XCTest
@testable import ForgeLoopCli
import ForgeLoopAI
import ForgeLoopAgent

final class SessionActivityTests: XCTestCase {
    private func assistant(_ stopReason: StopReason) -> Message {
        .assistant(AssistantMessage(
            content: [.text(TextContent(text: ""))],
            stopReason: stopReason,
            errorMessage: stopReason == .error ? "boom" : nil
        ))
    }

    func testStartsIdle() {
        XCTAssertEqual(SessionActivityTracker().activity, .idle)
    }

    func testAgentStartMarksWorking() {
        var tracker = SessionActivityTracker()
        XCTAssertTrue(tracker.apply(.agentStart))
        XCTAssertEqual(tracker.activity, .working)
    }

    func testCleanAgentEndMarksDone() {
        var tracker = SessionActivityTracker()
        tracker.apply(.agentStart)
        XCTAssertTrue(tracker.apply(.agentEnd(messages: [assistant(.endTurn)])))
        XCTAssertEqual(tracker.activity, .done)
    }

    func testErrorAgentEndMarksNeedsAttention() {
        var tracker = SessionActivityTracker()
        tracker.apply(.agentStart)
        XCTAssertTrue(tracker.apply(.agentEnd(messages: [assistant(.error)])))
        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    func testAbortedAgentEndMarksIdle() {
        var tracker = SessionActivityTracker()
        tracker.apply(.agentStart)
        XCTAssertTrue(tracker.apply(.agentEnd(messages: [assistant(.aborted)])))
        XCTAssertEqual(tracker.activity, .idle)
    }

    func testAgentEndWithoutAssistantMessageMarksDone() {
        var tracker = SessionActivityTracker()
        tracker.apply(.agentStart)
        XCTAssertTrue(tracker.apply(.agentEnd(messages: [])))
        XCTAssertEqual(tracker.activity, .done)
    }

    func testIntermediateEventsDoNotChangeActivity() {
        var tracker = SessionActivityTracker()
        XCTAssertFalse(tracker.apply(.turnStart))
        XCTAssertFalse(tracker.apply(.toolExecutionStart(toolCallId: "1", toolName: "read", args: "{}")))
        XCTAssertEqual(tracker.activity, .idle)
    }

    func testMarkSeenClearsDoneAndNeedsAttentionOnly() {
        var tracker = SessionActivityTracker()
        tracker.apply(.agentStart)
        XCTAssertFalse(tracker.markSeen())
        XCTAssertEqual(tracker.activity, .working)

        tracker.apply(.agentEnd(messages: [assistant(.endTurn)]))
        XCTAssertTrue(tracker.markSeen())
        XCTAssertEqual(tracker.activity, .idle)

        tracker.apply(.agentStart)
        tracker.apply(.agentEnd(messages: [assistant(.error)]))
        XCTAssertTrue(tracker.markSeen())
        XCTAssertEqual(tracker.activity, .idle)
    }

    func testNewRunSupersedesRestingState() {
        var tracker = SessionActivityTracker()
        tracker.apply(.agentStart)
        tracker.apply(.agentEnd(messages: [assistant(.error)]))
        XCTAssertTrue(tracker.apply(.agentStart))
        XCTAssertEqual(tracker.activity, .working)
    }

    func testAggregatePriority() {
        XCTAssertEqual(aggregateSessionActivity([]), .idle)
        XCTAssertEqual(aggregateSessionActivity([.idle, .working]), .working)
        XCTAssertEqual(aggregateSessionActivity([.working, .done]), .done)
        XCTAssertEqual(aggregateSessionActivity([.done, .needsAttention, .working]), .needsAttention)
    }
}
