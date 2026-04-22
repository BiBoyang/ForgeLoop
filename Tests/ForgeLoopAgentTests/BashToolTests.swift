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
        XCTAssertTrue(result.output.contains("Missing required argument"))
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
