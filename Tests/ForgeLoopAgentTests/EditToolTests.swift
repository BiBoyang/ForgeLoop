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
        XCTAssertTrue(result.output.contains("Edited test.txt (1 replacement)"))
        XCTAssertTrue(result.output.contains("--- old"))
        XCTAssertTrue(result.output.contains("+++ new"))
        XCTAssertTrue(result.output.contains("-hello"))
        XCTAssertTrue(result.output.contains("+hi"))

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
        XCTAssertTrue(result.output.contains("Edited test.txt (1 replacement)"))
        XCTAssertTrue(result.output.contains("-OLD"))
        XCTAssertTrue(result.output.contains("+NEW"))
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(content, "line1\nNEW\nline3")
    }

    // MARK: - 8) Multi-line diff summary

    func testMultilineDiffSummary() async throws {
        let filePath = "\(tempDir!)/test.txt"
        try "line1\nOLD_LINE_A\nOLD_LINE_B\nline4".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = EditTool()
        let result = await tool.execute(
            arguments: #"{"path":"test.txt","oldText":"OLD_LINE_A\nOLD_LINE_B","newText":"NEW_LINE_A\nNEW_LINE_B"}"#,
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Edited test.txt (1 replacement)"))
        XCTAssertTrue(result.output.contains("--- old"))
        XCTAssertTrue(result.output.contains("+++ new"))
        XCTAssertTrue(result.output.contains("-OLD_LINE_A"))
        XCTAssertTrue(result.output.contains("-OLD_LINE_B"))
        XCTAssertTrue(result.output.contains("+NEW_LINE_A"))
        XCTAssertTrue(result.output.contains("+NEW_LINE_B"))
    }

    // MARK: - 9) Long diff truncation

    func testLongDiffTruncation() async throws {
        let filePath = "\(tempDir!)/test.txt"
        let longOld = String(repeating: "a", count: 300)
        let longNew = String(repeating: "b", count: 300)
        try longOld.write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = EditTool(maxDiffPreviewChars: 50)
        let result = await tool.execute(
            arguments: "{\"path\":\"test.txt\",\"oldText\":\"\(longOld)\",\"newText\":\"\(longNew)\"}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Edited test.txt (1 replacement)"))
        XCTAssertTrue(result.output.contains("[diff truncated: exceeded limit]"))
    }

    // MARK: - 10) Schema validation rejects unknown fields

    func testSchemaRejectsUnknownField() async {
        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"test.txt\",\"oldText\":\"a\",\"newText\":\"b\",\"extra\":1}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("unknownField"))
    }

    // MARK: - 11) Backup is created before edit

    func testBackupIsCreated() async throws {
        let filePath = "\(tempDir!)/test.txt"
        try "original".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"test.txt\",\"oldText\":\"original\",\"newText\":\"modified\"}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        let backupPath = "\(filePath).bak"
        let backupExists = FileManager.default.fileExists(atPath: backupPath)
        XCTAssertTrue(backupExists)
        let backupContent = try String(contentsOfFile: backupPath, encoding: .utf8)
        XCTAssertEqual(backupContent, "original")
    }

    // MARK: - 12) Anchor narrows the match region

    func testAnchorMatch() async throws {
        let filePath = "\(tempDir!)/test.txt"
        try "A foo B foo".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"test.txt\",\"oldText\":\"foo\",\"newText\":\"bar\",\"anchor\":\"B \"}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(content, "A foo B bar")
    }

    // MARK: - 13) replaceAll replaces every occurrence

    func testReplaceAll() async throws {
        let filePath = "\(tempDir!)/test.txt"
        try "foo foo foo".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"test.txt\",\"oldText\":\"foo\",\"newText\":\"bar\",\"replaceAll\":true}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("3 replacements"))
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(content, "bar bar bar")
    }

    // MARK: - 14) caseInsensitive match

    func testCaseInsensitiveMatch() async throws {
        let filePath = "\(tempDir!)/test.txt"
        try "Hello World".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"test.txt\",\"oldText\":\"hello\",\"newText\":\"hi\",\"caseInsensitive\":true}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(content, "hi World")
    }

    // MARK: - 15) lineNumber restricts replacement

    func testLineNumberRestriction() async throws {
        let filePath = "\(tempDir!)/test.txt"
        try "foo\nbar\nfoo".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"test.txt\",\"oldText\":\"foo\",\"newText\":\"baz\",\"lineNumber\":3}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError)
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(content, "foo\nbar\nbaz")
    }

    // MARK: - 16) Non-unique match within anchor reports error

    func testNonUniqueMatchWithAnchorReturnsError() async throws {
        let filePath = "\(tempDir!)/test.txt"
        try "A foo foo".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = EditTool()
        let result = await tool.execute(
            arguments: "{\"path\":\"test.txt\",\"oldText\":\"foo\",\"newText\":\"bar\",\"anchor\":\"A \"}",
            cwd: tempDir,
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("2 matches"))
    }
}
