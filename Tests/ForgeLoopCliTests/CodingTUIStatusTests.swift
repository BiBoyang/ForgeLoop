import XCTest
@testable import ForgeLoopCli
@testable import ForgeLoopAgent

final class CodingTUIStatusTests: XCTestCase {
    func testResolveStatusPhasePrefersModelPicker() {
        let phase = resolveStatusPhase(
            isStreaming: true,
            isAborting: true,
            isSelectingModel: true,
            hasRunningBackgroundTasks: true
        )

        XCTAssertEqual(phase, .selectingModel)
    }

    func testResolveStatusPhasePrefersAbortingOverGenerating() {
        let phase = resolveStatusPhase(
            isStreaming: true,
            isAborting: true,
            isSelectingModel: false,
            hasRunningBackgroundTasks: false
        )

        XCTAssertEqual(phase, .aborting)
    }

    func testResolveStatusPhaseUsesBackgroundStateWhenIdle() {
        let phase = resolveStatusPhase(
            isStreaming: false,
            isAborting: false,
            isSelectingModel: false,
            hasRunningBackgroundTasks: true
        )

        XCTAssertEqual(phase, .runningBackgroundTasks)
    }

    func testSummarizeBackgroundTasksCountsEachStatus() {
        let now = Date()
        let tasks = [
            BackgroundTaskRecord(id: "a", command: "one", startedAt: now, status: .running),
            BackgroundTaskRecord(id: "b", command: "two", startedAt: now, status: .running),
            BackgroundTaskRecord(id: "c", command: "three", startedAt: now, status: .success),
            BackgroundTaskRecord(id: "d", command: "four", startedAt: now, status: .failed),
            BackgroundTaskRecord(id: "e", command: "five", startedAt: now, status: .cancelled),
        ]

        let summary = summarizeBackgroundTasks(tasks)

        XCTAssertEqual(summary.runningCount, 2)
        XCTAssertEqual(summary.successCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.cancelledCount, 1)
    }

    func testMakeStatusLinesShowsReadyStateAndModel() {
        let lines = makeStatusLines(
            snapshot: CodingStatusSnapshot(
                modelLabel: "faux-coding-model · local scaffold",
                phase: .ready,
                pendingToolCount: 0,
                queuedMessageCount: 0,
                backgroundTasks: BackgroundTaskSummary()
            )
        )

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("ready"))
        XCTAssertTrue(lines[0].contains("faux-coding-model"))
    }

    func testMakeStatusLinesShowsBadgesForToolsBackgroundAndQueue() {
        let lines = makeStatusLines(
            snapshot: CodingStatusSnapshot(
                modelLabel: "GPT-4o (gpt-4o)",
                phase: .generating,
                pendingToolCount: 2,
                queuedMessageCount: 3,
                backgroundTasks: BackgroundTaskSummary(
                    runningCount: 1,
                    successCount: 0,
                    failedCount: 1,
                    cancelledCount: 1
                )
            )
        )

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("generating"))
        XCTAssertTrue(lines[1].contains("2 tools pending"))
        XCTAssertTrue(lines[1].contains("1 bg running"))
        XCTAssertTrue(lines[1].contains("1 bg failed"))
        XCTAssertTrue(lines[1].contains("1 bg cancelled"))
        XCTAssertTrue(lines[1].contains("3 queued"))
    }

    func testMakeFooterNoticeLinesFormatsMultilineFeedback() {
        let lines = makeFooterNoticeLines("""
        Available commands:
          /help
          /quit
        """)

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("▸ Available commands:"))
        XCTAssertTrue(lines[1].contains("/help"))
        XCTAssertTrue(lines[2].contains("/quit"))
    }
}
