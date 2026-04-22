import XCTest
@testable import ForgeLoopAgent

final class BuiltinReadWriteToolTests: XCTestCase {
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

    // MARK: - ReadTool

    func testReadExistingFile() async throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        let filePath = "\(dir)/test.txt"
        try "hello world".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = ReadTool()
        let result = await tool.execute(arguments: "{\"path\":\"test.txt\"}", cwd: dir, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.output, "hello world")
    }

    func testReadNonexistentFileReturnsError() async throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        let tool = ReadTool()
        let result = await tool.execute(arguments: "{\"path\":\"noexist.txt\"}", cwd: dir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("not found"))
    }

    func testReadDirectoryReturnsError() async throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        try FileManager.default.createDirectory(atPath: "\(dir)/subdir", withIntermediateDirectories: true)

        let tool = ReadTool()
        let result = await tool.execute(arguments: "{\"path\":\"subdir\"}", cwd: dir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("directory"))
    }

    func testReadOutsideCwdReturnsError() async throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        let tool = ReadTool()
        let result = await tool.execute(arguments: "{\"path\":\"../outside.txt\"}", cwd: dir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("outside"))
    }

    // MARK: - WriteTool

    func testWriteNewFile() async throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        let tool = WriteTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"new.txt\",\"content\":\"new content\"}",
            cwd: dir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Wrote"))

        let read = try String(contentsOfFile: "\(dir)/new.txt", encoding: .utf8)
        XCTAssertEqual(read, "new content")
    }

    func testWriteOverwritesExistingFile() async throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        try "old".write(toFile: "\(dir)/file.txt", atomically: true, encoding: .utf8)

        let tool = WriteTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"file.txt\",\"content\":\"new\"}",
            cwd: dir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)

        let read = try String(contentsOfFile: "\(dir)/file.txt", encoding: .utf8)
        XCTAssertEqual(read, "new")
    }

    func testWriteCreatesSubdirectories() async throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        let tool = WriteTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"a/b/c.txt\",\"content\":\"nested\"}",
            cwd: dir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)

        let read = try String(contentsOfFile: "\(dir)/a/b/c.txt", encoding: .utf8)
        XCTAssertEqual(read, "nested")
    }

    func testWriteToDirectoryReturnsError() async throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        try FileManager.default.createDirectory(atPath: "\(dir)/existing_dir", withIntermediateDirectories: true)

        let tool = WriteTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"existing_dir\",\"content\":\"x\"}",
            cwd: dir,
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("directory"))
    }

    func testWriteOutsideCwdReturnsError() async throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        let tool = WriteTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"../escape.txt\",\"content\":\"bad\"}",
            cwd: dir,
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("outside"))
    }

    // MARK: - PathGuard

    func testPathGuardResolvesRelativePath() throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        let guard_ = PathGuard(cwd: dir)
        let url = try guard_.resolve("file.txt")
        XCTAssertEqual(url.path, "\(dir)/file.txt")
    }

    func testPathGuardRejectsDirectoryTraversal() throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        let guard_ = PathGuard(cwd: "\(dir)/sub")
        XCTAssertThrowsError(try guard_.resolve("../../etc/passwd")) { error in
            guard case PathError.outsideCwd = error else {
                XCTFail("Expected outsideCwd error")
                return
            }
        }
    }

    func testPathGuardAllowsSameLevel() throws {
        let dir = setupTempDir()
        defer { cleanup(dir) }

        let guard_ = PathGuard(cwd: dir)
        let url = try guard_.resolve("./file.txt")
        XCTAssertEqual(url.path, "\(dir)/file.txt")
    }
}
