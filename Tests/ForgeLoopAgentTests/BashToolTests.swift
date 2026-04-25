import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

final class BashToolTests: XCTestCase {
    private var tempDir: String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
    }

    private func setupTempDir() -> String {
        let dir = tempDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - 正常执行

    func testEchoCommand() async throws {
        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{\"command\":\"echo hello\"}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("hello"))
    }

    func testCommandInCwd() async throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        try "cwd-test".write(toFile: "\(dir)/file.txt", atomically: true, encoding: .utf8)

        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{\"command\":\"cat file.txt\"}",
            cwd: dir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "cwd-test")
    }

    func testExitCodeNonZeroReturnsError() async throws {
        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{\"command\":\"exit 42\"}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("42") || result.output.contains("Exit code"))
    }

    func testStderrCaptured() async throws {
        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{\"command\":\"echo error-msg >&2\"}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("[stderr]"))
        XCTAssertTrue(result.output.contains("error-msg"))
    }

    func testMissingCommandArgument() async throws {
        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("missingRequired"))
        XCTAssertTrue(result.output.contains("$.command"))
    }

    // MARK: - 参数校验

    func testInvalidJsonReturnsError() async {
        let tool = BashTool()
        let result = await tool.execute(arguments: "not json", cwd: "/tmp", cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidJson"))
    }

    func testUnknownFieldReturnsError() async {
        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{\"command\":\"echo hi\",\"extra\":1}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("unknownField"))
        XCTAssertTrue(result.output.contains("$.extra"))
    }

    func testInvalidModeReturnsError() async {
        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{\"command\":\"echo hi\",\"mode\":\"invalid\"}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidType"))
        XCTAssertTrue(result.output.contains("$.mode"))
    }

    func testInvalidTimeoutMsReturnsError() async {
        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{\"command\":\"echo hi\",\"timeoutMs\":0}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidType"))
        XCTAssertTrue(result.output.contains("$.timeoutMs"))
    }

    // MARK: - background mode

    func testBackgroundModeStartsTask() async {
        let manager = BackgroundTaskManager()
        let tool = BashTool(manager: manager)
        let result = await tool.execute(
            arguments: "{\"command\":\"echo hello\",\"mode\":\"background\"}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Started background task:"))

        let tasks = await manager.status()
        XCTAssertEqual(tasks.count, 1)
    }

    func testBackgroundModeWithoutManagerReturnsNotImplemented() async {
        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{\"command\":\"echo hello\",\"mode\":\"background\"}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("notImplemented"))
    }

    // MARK: - 非交互环境注入

    func testPagerEnvironmentVariablesInjected() async throws {
        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{\"command\":\"printf '%s|%s' \\\"$PAGER\\\" \\\"$GIT_PAGER\\\"\"}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("cat|cat"), "Expected PAGER=cat and GIT_PAGER=cat, got: \(result.output)")
    }

    func testStdinNullDeviceDoesNotHang() async throws {
        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{\"command\":\"cat\",\"timeoutMs\":500}",
            cwd: "/tmp",
            cancellation: nil
        )

        // cat with no stdin should return quickly (empty), not timeout
        XCTAssertFalse(result.output.contains("timed out"), "Expected cat to return quickly with null stdin, but it timed out: \(result.output)")
        XCTAssertFalse(result.isError, "Expected cat with null stdin to succeed, got error: \(result.output)")
    }

    // MARK: - 超时

    func testTimeoutKillsProcess() async throws {
        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{\"command\":\"sleep 10\",\"timeoutMs\":100}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("timed out"))
    }

    // MARK: - 取消

    func testCancellationAbortsProcess() async throws {
        let cancellation = CancellationHandle()

        let tool = BashTool()

        let task = Task {
            await tool.execute(
                arguments: "{\"command\":\"sleep 10\"}",
                cwd: "/tmp",
                cancellation: cancellation
            )
        }

        // 稍微等待进程启动
        try? await Task.sleep(nanoseconds: 50_000_000)
        cancellation.cancel(reason: "test-abort")

        let result = await task.value
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("aborted") || result.output.contains("timed out"))
    }

    // MARK: - 输出限制

    func testLargeOutputHandled() async throws {
        let tool = BashTool()
        let result = await tool.execute(
            arguments: "{\"command\":\"yes | head -n 10000\"}",
            cwd: "/tmp",
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        // 输出可能被截断，但至少应该有内容
        XCTAssertFalse(result.output.isEmpty)
    }
}
