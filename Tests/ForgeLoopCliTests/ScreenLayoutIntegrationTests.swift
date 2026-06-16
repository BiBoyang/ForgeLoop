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

    // MARK: - CR-02 composition proof: CLI composes TUI library, not reimplements

    /// Proves that ``CodingTUIFrameBuilder`` delegates entirely to
    /// ``ScreenLayoutRenderer`` and does not inject app-local rendering logic.
    ///
    /// ## Proof strategy
    /// 1. Build a frame through the CLI composition path (`CodingTUIFrameBuilder.build`).
    /// 2. Build an equivalent frame directly through the library (`ScreenLayoutRenderer.render`).
    /// 3. Assert byte-identical output — any divergence means app-local logic has leaked in.
    /// 4. Assert the coalescing contract still holds with the builder output.
    /// 5. Assert the visual-order contract (header < transcript < queue < status < input).
    ///
    /// ## Regression guard (回滚防线)
    /// If someone reintroduces a local `TUIRunner`, `LayoutRenderer`, or `KeyEvent`
    /// alternative and subtly alters frame construction inside the builder, the
    /// byte-identical assertion will fail — catching the regression at compile/test time.
    func testBuilderDelegatesToLibraryRendererWithoutAlteringOutput() {
        let renderer = ScreenLayoutRenderer()
        let cursor = CursorPlacement(up: 0, offset: 3)
        let input = CodingTUIFrameBuilder.Input(
            headerLines: ["H"],
            transcriptLines: ["T1", "T2"],
            queueLines: ["Q"],
            statusLines: ["S"],
            inputLines: ["> prompt"],
            terminalHeight: 24,
            terminalWidth: 80,
            showHeader: true,
            cursorPlacement: cursor
        )

        // Path A: CLI composition (production code path).
        let frame = CodingTUIFrameBuilder.build(input: input, renderer: renderer)

        // Path B: direct library call (baseline).
        let layout = ScreenLayout(
            header: input.headerLines,
            transcript: input.transcriptLines,
            queue: input.queueLines,
            status: input.statusLines,
            input: input.inputLines,
            pinnedTranscriptRange: input.pinnedTranscriptRange
        )
        let config = ScreenLayoutConfig(
            terminalHeight: input.terminalHeight,
            terminalWidth: input.terminalWidth,
            showHeader: input.showHeader
        )
        let directFrame = renderer.render(layout: layout, config: config, cursorPlacement: cursor)

        // Composition proof: builder must not alter any aspect of library output.
        XCTAssertEqual(
            frame.committed,
            directFrame.committed,
            "Builder must not mutate committed region — must delegate to library"
        )
        XCTAssertEqual(
            frame.live,
            directFrame.live,
            "Builder must not mutate live region — must delegate to library"
        )
        XCTAssertEqual(
            frame.cursorPlacement,
            directFrame.cursorPlacement,
            "Builder must preserve cursor placement through to library"
        )
        XCTAssertEqual(
            frame.committed + frame.live,
            directFrame.committed + directFrame.live,
            "Full visual reconstruction must be identical between builder and library"
        )

        // Regression guard: coalescing contract must hold with builder output.
        XCTAssertFalse(
            shouldCoalesceWithRenderLoop(frame: frame, priority: .normal),
            "Live content via builder path must block coalescing (library contract)"
        )

        // Regression guard: visual-order contract must hold with builder output.
        let flat = frame.committed + frame.live
        let hIdx = flat.firstIndex(of: "H")
        let tIdx = flat.firstIndex(of: "T1")
        let qIdx = flat.firstIndex(of: "Q")
        let sIdx = flat.firstIndex(of: "S")
        let iIdx = flat.firstIndex(of: "> prompt")
        XCTAssertNotNil(hIdx, "Header region must be present in composition path")
        XCTAssertNotNil(tIdx, "Transcript region must be present in composition path")
        XCTAssertNotNil(qIdx, "Queue region must be present in composition path")
        XCTAssertNotNil(sIdx, "Status region must be present in composition path")
        XCTAssertNotNil(iIdx, "Input region must be present in composition path")
        XCTAssertLessThan(hIdx!, tIdx!, "Order contract: header < transcript")
        XCTAssertLessThan(tIdx!, qIdx!, "Order contract: transcript < queue")
        XCTAssertLessThan(qIdx!, sIdx!, "Order contract: queue < status")
        XCTAssertLessThan(sIdx!, iIdx!, "Order contract: status < input (live)")
    }
}
