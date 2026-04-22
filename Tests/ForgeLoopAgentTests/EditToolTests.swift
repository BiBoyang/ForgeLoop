import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

final class EditToolTests: XCTestCase {
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - 1) Basic edit replaces first occurrence

    func testBasicEditReplacesFirstOccurrence() async throws {
        let filePath = "\(tempDir!)/test.txt"
        try "hello world hello".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"test.txt\",\"oldText\":\"hello\",\"newText\":\"hi\"}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Edited"))

        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(content, "hi world hello")
    }

    // MARK: - 2) Edit file not found returns error

    func testEditMissingFileReturnsError() async {
        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"missing.txt\",\"oldText\":\"a\",\"newText\":\"b\"}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("not found") || result.output.contains("File not found"))
    }

    // MARK: - 3) Edit directory path returns error

    func testEditDirectoryReturnsError() async {
        let dirPath = "\(tempDir!)/subdir"
        try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)

        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"subdir\",\"oldText\":\"a\",\"newText\":\"b\"}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("directory"))
    }

    // MARK: - 4) Old text not found returns error

    func testOldTextNotFoundReturnsError() async throws {
        let filePath = "\(tempDir!)/test.txt"
        try "hello world".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"test.txt\",\"oldText\":\"nonexistent\",\"newText\":\"hi\"}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Could not find"))
    }

    // MARK: - 5) Path outside cwd rejected

    func testPathOutsideCwdRejected() async {
        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"../outside.txt\",\"oldText\":\"a\",\"newText\":\"b\"}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("outside"))
    }

    // MARK: - 6) Missing arguments return error

    func testMissingArgumentsReturnsError() async {
        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"test.txt\"}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Missing"))
    }

    // MARK: - 7) Multi-line replacement works

    func testMultilineReplacement() async throws {
        let filePath = "\(tempDir!)/test.txt"
        try "line1\nOLD\nline3".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"test.txt\",\"oldText\":\"OLD\",\"newText\":\"NEW\"}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(content, "line1\nNEW\nline3")
    }
}
