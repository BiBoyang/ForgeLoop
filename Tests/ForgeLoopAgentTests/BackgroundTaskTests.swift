import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

final class BackgroundTaskTests: XCTestCase {

    // MARK: - 1) Start a background task and get an ID

    func testStartReturnsTaskID() async {
        let manager = BackgroundTaskManager()
        let id = await manager.start(command: "echo hello", cwd: "/tmp")

        XCTAssertEqual(id.count, 8)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit })
    }

    // MARK: - 2) Query status returns running tasks

    func testStatusReturnsRunningTasks() async {
        let manager = BackgroundTaskManager()
        let id = await manager.start(command: "sleep 0.5", cwd: "/tmp")

        let tasks = await manager.status()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].id, id)
        XCTAssertEqual(tasks[0].status, .running)
        XCTAssertEqual(tasks[0].command, "sleep 0.5")
    }

    // MARK: - 3) Query specific task by ID

    func testStatusByID() async {
        let manager = BackgroundTaskManager()
        let id = await manager.start(command: "echo test", cwd: "/tmp")

        let tasks = await manager.status(id: id)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].id, id)
    }

    func testStatusByUnknownIDReturnsEmpty() async {
        let manager = BackgroundTaskManager()
        let tasks = await manager.status(id: "nonexistent")
        XCTAssertTrue(tasks.isEmpty)
    }

    // MARK: - 4) Task completion updates status

    func testTaskCompletionUpdatesStatus() async throws {
        let manager = BackgroundTaskManager()
        let id = await manager.start(command: "echo done", cwd: "/tmp")

        // Wait for the task to complete
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        let tasks = await manager.status(id: id)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].status, .success)
        XCTAssertNotNil(tasks[0].finishedAt)
        XCTAssertTrue(tasks[0].output.contains("done"))
    }

    // MARK: - 5) Failed task reports failed status

    func testFailedTaskReportsFailed() async throws {
        let manager = BackgroundTaskManager()
        let id = await manager.start(command: "exit 1", cwd: "/tmp")

        try await Task.sleep(nanoseconds: 200_000_000)

        let tasks = await manager.status(id: id)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].status, .failed)
        XCTAssertEqual(tasks[0].exitCode, 1)
    }

    // MARK: - 6) Completion handler is called

    func testCompletionHandlerCalled() async throws {
        let manager = BackgroundTaskManager()
        actor CompletionTracker {
            var completed: BackgroundTaskRecord?
            func set(_ record: BackgroundTaskRecord) { completed = record }
        }
        let tracker = CompletionTracker()

        await manager.setCompletionHandler { record in
            await tracker.set(record)
        }

        let id = await manager.start(command: "echo handler_test", cwd: "/tmp")
        try await Task.sleep(nanoseconds: 300_000_000)

        let completed = await tracker.completed
        XCTAssertNotNil(completed)
        XCTAssertEqual(completed?.id, id)
        XCTAssertEqual(completed?.status, .success)
    }

    // MARK: - 7) BgTool starts a task

    func testBgToolStartsTask() async {
        let manager = BackgroundTaskManager()
        let tool = BgTool(manager: manager)

        let result = await tool.execute(
            arguments: "{\"command\":\"echo hello\"}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Started"))
    }

    func testBgToolMissingCommand() async {
        let manager = BackgroundTaskManager()
        let tool = BgTool(manager: manager)

        let result = await tool.execute(arguments: "{}", cwd: "/tmp", cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Missing"))
    }

    // MARK: - 8) BgStatusTool queries tasks

    func testBgStatusToolReturnsTasks() async throws {
        let manager = BackgroundTaskManager()
        let id = await manager.start(command: "echo test", cwd: "/tmp")

        let statusTool = BgStatusTool(manager: manager)
        let result = await statusTool.execute(
            arguments: "{\"id\":\"\(id)\"}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains(id))
    }

    func testBgStatusToolEmptyState() async {
        let manager = BackgroundTaskManager()
        let statusTool = BgStatusTool(manager: manager)

        let result = await statusTool.execute(arguments: "{}", cwd: "/tmp", cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("no background tasks"))
    }

    func testBgStatusToolUnknownID() async {
        let manager = BackgroundTaskManager()
        let statusTool = BgStatusTool(manager: manager)

        let result = await statusTool.execute(
            arguments: "{\"id\":\"unknown\"}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("No task found"))
    }

    // MARK: - 9) Multiple tasks tracked independently

    func testMultipleTasksTracked() async {
        let manager = BackgroundTaskManager()
        let id1 = await manager.start(command: "echo one", cwd: "/tmp")
        let id2 = await manager.start(command: "echo two", cwd: "/tmp")

        let tasks = await manager.status()
        XCTAssertEqual(tasks.count, 2)

        let ids = tasks.map(\.id).sorted()
        XCTAssertEqual(ids, [id1, id2].sorted())
    }

    // MARK: - 10) Cancel terminates running task

    func testCancelTerminatesRunningTask() async throws {
        let manager = BackgroundTaskManager()
        let id = await manager.start(command: "sleep 10", cwd: "/tmp")

        // Verify it's running
        let running = await manager.status(id: id)
        XCTAssertEqual(running[0].status, .running)

        // Cancel it
        await manager.cancel(id: id, by: "test")

        let cancelled = await manager.status(id: id)
        XCTAssertEqual(cancelled[0].status, .cancelled)
        XCTAssertEqual(cancelled[0].cancelledBy, "test")
        XCTAssertNotNil(cancelled[0].finishedAt)
    }

    // MARK: - 11) Cancelled task does not trigger completion handler

    func testCancelledTaskDoesNotTriggerCompletionHandler() async throws {
        let manager = BackgroundTaskManager()
        actor CompletionTracker {
            var callCount = 0
            func increment() { callCount += 1 }
        }
        let tracker = CompletionTracker()

        await manager.setCompletionHandler { _ in
            await tracker.increment()
        }

        let id = await manager.start(command: "sleep 10", cwd: "/tmp")
        await manager.cancel(id: id)

        try await Task.sleep(nanoseconds: 200_000_000)

        let count = await tracker.callCount
        XCTAssertEqual(count, 0, "Cancelled task should not trigger completion handler")
    }

    // MARK: - 12) Completed task cannot be cancelled again

    func testCancelCompletedTaskIsNoOp() async throws {
        let manager = BackgroundTaskManager()
        let id = await manager.start(command: "echo done", cwd: "/tmp")

        try await Task.sleep(nanoseconds: 200_000_000)

        let before = await manager.status(id: id)
        XCTAssertEqual(before[0].status, .success)

        await manager.cancel(id: id)

        let after = await manager.status(id: id)
        XCTAssertEqual(after[0].status, .success)
    }

    // MARK: - 非交互环境继承

    func testBgTaskInheritsPagerEnvironment() async throws {
        let manager = BackgroundTaskManager()
        let id = await manager.start(command: "echo \"$PAGER\"", cwd: "/tmp")

        try await Task.sleep(nanoseconds: 200_000_000)

        let tasks = await manager.status(id: id)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].status, .success)
        XCTAssertTrue(tasks[0].output.contains("cat"), "Expected PAGER=cat in bg output, got: \(tasks[0].output)")
    }

    // MARK: - 13) Cancel source appears in bg_status output

    func testCancelSourceInStatus() async {
        let manager = BackgroundTaskManager()
        let id = await manager.start(command: "sleep 10", cwd: "/tmp")
        await manager.cancel(id: id, by: "system")

        let statusTool = BgStatusTool(manager: manager)
        let result = await statusTool.execute(
            arguments: "{\"id\":\"\(id)\"}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("[by: system]"))
    }

    // MARK: - 14) Cancel all running tasks

    func testCancelAllCancelsOnlyRunningTasks() async throws {
        let manager = BackgroundTaskManager()
        _ = await manager.start(command: "sleep 10", cwd: "/tmp")
        _ = await manager.start(command: "sleep 10", cwd: "/tmp")
        _ = await manager.start(command: "echo done", cwd: "/tmp")

        try await Task.sleep(nanoseconds: 200_000_000)

        let cancelledCount = await manager.cancelAll(by: "bulk-test")
        XCTAssertEqual(cancelledCount, 2)

        let allTasks = await manager.status()
        let cancelled = allTasks.filter { $0.status == .cancelled }
        XCTAssertEqual(cancelled.count, 2)
        XCTAssertTrue(cancelled.allSatisfy { $0.cancelledBy == "bulk-test" })
    }
}
