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
                attachmentCount: 0,
                backgroundTasks: BackgroundTaskSummary(),
                didCompactRecently: false
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
                attachmentCount: 0,
                backgroundTasks: BackgroundTaskSummary(
                    runningCount: 1,
                    successCount: 0,
                    failedCount: 1,
                    cancelledCount: 1
                ),
                didCompactRecently: false
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

    func testMakeStatusLinesShowsAttachmentBadgeWhenPresent() {
        let lines = makeStatusLines(
            snapshot: CodingStatusSnapshot(
                modelLabel: "test",
                phase: .ready,
                pendingToolCount: 0,
                queuedMessageCount: 0,
                attachmentCount: 2,
                backgroundTasks: BackgroundTaskSummary(),
                didCompactRecently: false
            )
        )

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("2 attachments"), "Expected '2 attachments' in \(lines[1])")
    }

    func testMakeStatusLinesShowsOneAttachmentSingular() {
        let lines = makeStatusLines(
            snapshot: CodingStatusSnapshot(
                modelLabel: "test",
                phase: .ready,
                pendingToolCount: 0,
                queuedMessageCount: 0,
                attachmentCount: 1,
                backgroundTasks: BackgroundTaskSummary(),
                didCompactRecently: false
            )
        )

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("1 attachment"))
        XCTAssertFalse(lines[1].contains("1 attachments"))
    }

    func testMakeStatusLinesNoAttachmentBadgeWhenZero() {
        let lines = makeStatusLines(
            snapshot: CodingStatusSnapshot(
                modelLabel: "test",
                phase: .ready,
                pendingToolCount: 0,
                queuedMessageCount: 0,
                attachmentCount: 0,
                backgroundTasks: BackgroundTaskSummary(),
                didCompactRecently: false
            )
        )

        XCTAssertEqual(lines.count, 1)
    }

    func testMakeStatusLinesBadgeOrderIsToolsQueuedAttachmentsBg() {
        let lines = makeStatusLines(
            snapshot: CodingStatusSnapshot(
                modelLabel: "test",
                phase: .ready,
                pendingToolCount: 1,
                queuedMessageCount: 2,
                attachmentCount: 3,
                backgroundTasks: BackgroundTaskSummary(runningCount: 4),
                didCompactRecently: false
            )
        )

        XCTAssertEqual(lines.count, 2)
        let badgeLine = lines[1]
        let toolIndex = badgeLine.range(of: "1 tool pending")?.lowerBound.utf16Offset(in: badgeLine) ?? -1
        let queuedIndex = badgeLine.range(of: "2 queued")?.lowerBound.utf16Offset(in: badgeLine) ?? -1
        let attachIndex = badgeLine.range(of: "3 attachments")?.lowerBound.utf16Offset(in: badgeLine) ?? -1
        let bgIndex = badgeLine.range(of: "4 bg running")?.lowerBound.utf16Offset(in: badgeLine) ?? -1

        XCTAssertTrue(toolIndex < queuedIndex, "tools should come before queued")
        XCTAssertTrue(queuedIndex < attachIndex, "queued should come before attachments")
        XCTAssertTrue(attachIndex < bgIndex, "attachments should come before bg")
    }

    // MARK: - makeInputLines

    func testMakeInputLinesWithoutAttachmentsReturnsOnlyInputLine() {
        let lines = makeInputLines(inputLine: "❯ hello", attachmentCount: 0)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0], "❯ hello")
    }

    func testMakeInputLinesWithAttachmentsPutsHintAboveInputLine() {
        let lines = makeInputLines(inputLine: "❯ ", attachmentCount: 2)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("2 attachments"))
        XCTAssertEqual(lines[1], "❯ ")
    }

    func testMakeInputLinesSingularAttachment() {
        let lines = makeInputLines(inputLine: "❯ ", attachmentCount: 1)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("1 attachment"))
        XCTAssertFalse(lines[0].contains("1 attachments"))
    }

    func testMakeInputLinesPromptLineIsAlwaysLast() {
        let promptLine = "❯ some input here"
        let lines = makeInputLines(inputLine: promptLine, attachmentCount: 5)

        XCTAssertEqual(lines.last, promptLine)
    }

    // MARK: - FooterNotice

    func testFooterNoticeInitFormatsLinesWithWarningPrefix() {
        let notice = FooterNotice(text: "hello world", priority: .command)

        XCTAssertEqual(notice.lines.count, 1)
        XCTAssertTrue(notice.lines[0].contains("▸ hello world"))
    }

    func testFooterNoticePriorityComparable() {
        XCTAssertTrue(FooterNotice.Priority.info < .command)
        XCTAssertTrue(FooterNotice.Priority.command < .error)
        XCTAssertTrue(FooterNotice.Priority.info < .error)
        XCTAssertFalse(FooterNotice.Priority.error < .command)
    }

    func testResolveFooterNoticeAcceptsWhenNil() {
        let incoming = FooterNotice(text: "new", priority: .command)
        let result = resolveFooterNotice(current: nil, incoming: incoming)

        XCTAssertEqual(result.lines, incoming.lines)
        XCTAssertEqual(result.priority, .command)
    }

    func testResolveFooterNoticeReplacesLowerPriority() {
        let current = FooterNotice(text: "old", priority: .info)
        let incoming = FooterNotice(text: "new", priority: .command)
        let result = resolveFooterNotice(current: current, incoming: incoming)

        XCTAssertEqual(result.priority, .command)
        XCTAssertTrue(result.lines[0].contains("new"))
    }

    func testResolveFooterNoticeReplacesEqualPriority() {
        let current = FooterNotice(text: "old", priority: .command)
        let incoming = FooterNotice(text: "new", priority: .command)
        let result = resolveFooterNotice(current: current, incoming: incoming)

        XCTAssertTrue(result.lines[0].contains("new"))
    }

    func testResolveFooterNoticePreservesHigherPriority() {
        let current = FooterNotice(text: "error msg", priority: .error)
        let incoming = FooterNotice(text: "info msg", priority: .info)
        let result = resolveFooterNotice(current: current, incoming: incoming)

        XCTAssertEqual(result.priority, .error)
        XCTAssertTrue(result.lines[0].contains("error msg"))
    }

    // MARK: - compacted badge

    func testMakeStatusLinesShowsCompactedBadge() {
        let lines = makeStatusLines(
            snapshot: CodingStatusSnapshot(
                modelLabel: "test",
                phase: .ready,
                pendingToolCount: 0,
                queuedMessageCount: 0,
                attachmentCount: 0,
                backgroundTasks: BackgroundTaskSummary(),
                didCompactRecently: true
            )
        )

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("compacted"), "Expected 'compacted' badge in \(lines[1])")
    }

    func testMakeStatusLinesNoCompactedBadgeWhenFalse() {
        let lines = makeStatusLines(
            snapshot: CodingStatusSnapshot(
                modelLabel: "test",
                phase: .ready,
                pendingToolCount: 0,
                queuedMessageCount: 0,
                attachmentCount: 0,
                backgroundTasks: BackgroundTaskSummary(),
                didCompactRecently: false
            )
        )

        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].contains("compacted"))
    }
}
