import XCTest
@testable import ForgeLoopCli
import ForgeLoopTUI

/// Validates that the CLI rendering path preserves live-region semantics
/// produced by ``ScreenLayoutRenderer`` and does not flatten them.
@MainActor
final class ScreenLayoutIntegrationTests: XCTestCase {

    private let renderer = ScreenLayoutRenderer()

    // MARK: - Live frame must not be coalesced away

    func testLiveFrameIsNotCoalescedToCommittedOnly() {
        let layout = ScreenLayout(
            transcript: ["t1", "t2"],
            input: ["> "]
        )
        let config = ScreenLayoutConfig(terminalHeight: 24)
        let frame = renderer.render(layout: layout, config: config)

        // The frame has a non-empty live region because input is present.
        XCTAssertFalse(frame.live.isEmpty, "Expected live to contain input divider + lines")

        // Coalescing must reject this frame so the full committed+live path is kept.
        XCTAssertFalse(
            shouldCoalesceWithRenderLoop(frame: frame, priority: .normal),
            "A frame with live content must not be coalesced into renderLoop.submit(committed:)"
        )
    }

    func testCursorAnchoredFrameIsNotCoalesced() {
        let layout = ScreenLayout(transcript: ["t1"], input: ["> hello"])
        let config = ScreenLayoutConfig(terminalHeight: 24)
        let frame = renderer.render(layout: layout, config: config, cursorOffset: 3)

        XCTAssertFalse(
            shouldCoalesceWithRenderLoop(frame: frame, priority: .normal),
            "A frame with cursorOffset must not be coalesced"
        )
    }

    // MARK: - Committed-only frame may still coalesce (existing optimization preserved)

    func testCommittedOnlyFrameCanStillCoalesce() {
        let layout = ScreenLayout(
            header: ["H"],
            transcript: ["T1", "T2"],
            status: ["S"]
        )
        let config = ScreenLayoutConfig(terminalHeight: 24)
        let frame = renderer.render(layout: layout, config: config)

        XCTAssertTrue(frame.live.isEmpty, "No input means no live region")
        XCTAssertTrue(
            shouldCoalesceWithRenderLoop(frame: frame, priority: .normal),
            "Pure committed frames should still be eligible for coalescing"
        )
    }

    func testEmptyFrameCanCoalesce() {
        let layout = ScreenLayout()
        let config = ScreenLayoutConfig(terminalHeight: 24)
        let frame = renderer.render(layout: layout, config: config)

        XCTAssertTrue(frame.live.isEmpty)
        XCTAssertTrue(
            shouldCoalesceWithRenderLoop(frame: frame, priority: .normal),
            "Empty frame should be coalescing-eligible"
        )
    }

    // MARK: - Priority gates are respected regardless of content

    func testImmediatePriorityRejectsCoalescingEvenForCommittedOnly() {
        let layout = ScreenLayout(transcript: ["t1"])
        let config = ScreenLayoutConfig(terminalHeight: 24)
        let frame = renderer.render(layout: layout, config: config)

        XCTAssertFalse(
            shouldCoalesceWithRenderLoop(frame: frame, priority: .immediate),
            "Immediate priority must always bypass coalescing"
        )
    }

    // MARK: - Structural sanity: committed + live reconstructs full visual order

    func testCommittedPlusLiveReconstructsFullVisualOrder() {
        let layout = ScreenLayout(
            header: ["H"],
            transcript: ["T"],
            queue: ["Q"],
            status: ["S"],
            input: ["I"]
        )
        let config = ScreenLayoutConfig(terminalHeight: 24)
        let frame = renderer.render(layout: layout, config: config)

        let flat = frame.committed + frame.live
        XCTAssertEqual(flat, [
            "H",
            "T",
            "",
            "Q",
            "",
            "S",
            "",
            "I",
        ])
    }

    // MARK: - Regression fixtures (must never regress)

    func testCommittedLiveReconstructionOrderIsStable() {
        // Fixture: committed + live must always reconstruct the same flat order.
        let layout = ScreenLayout(
            header: ["H"],
            transcript: ["T1", "T2"],
            queue: ["Q"],
            status: ["S"],
            input: ["I"]
        )
        let config = ScreenLayoutConfig(terminalHeight: 24)
        let frame = renderer.render(layout: layout, config: config)

        XCTAssertEqual(
            frame.committed + frame.live,
            ["H", "T1", "T2", "", "Q", "", "S", "", "I"],
            "Flat reconstruction order must remain stable across refactorings"
        )
    }

    func testLivePresenceAlwaysBlocksCoalescing() {
        // Fixture: any non-empty live region must prevent coalescing.
        let frame = ComposedFrame(committed: ["a"], live: ["live"], cursorOffset: nil)
        XCTAssertFalse(
            shouldCoalesceWithRenderLoop(frame: frame, priority: .normal),
            "Live presence must always block coalescing"
        )
    }

    func testCursorOffsetPresenceAlwaysBlocksCoalescing() {
        // Fixture: any cursorOffset must prevent coalescing.
        let frame = ComposedFrame(committed: ["a"], live: [], cursorOffset: 1)
        XCTAssertFalse(
            shouldCoalesceWithRenderLoop(frame: frame, priority: .normal),
            "cursorOffset presence must always block coalescing"
        )
    }

    func testImmediatePriorityAlwaysBlocksCoalescing() {
        // Fixture: immediate priority must always bypass coalescing.
        let frame = ComposedFrame(committed: ["a"], live: [], cursorOffset: nil)
        XCTAssertFalse(
            shouldCoalesceWithRenderLoop(frame: frame, priority: .immediate),
            "Immediate priority must always block coalescing regardless of frame content"
        )
    }
}
