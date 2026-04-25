import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

final class BuiltinSearchToolsTests: XCTestCase {
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

    // MARK: - ListTool (ls)

    func testListDirectoryContents() async {
        // Create some files and directories
        try? "content".write(toFile: "\(tempDir!)/file1.txt", atomically: true, encoding: .utf8)
        try? "content".write(toFile: "\(tempDir!)/file2.swift", atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(atPath: "\(tempDir!)/subdir", withIntermediateDirectories: true)

        let tool = ListTool()
        let result = await tool.execute(arguments: "{}", cwd: tempDir, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("- file1.txt"))
        XCTAssertTrue(result.output.contains("- file2.swift"))
        XCTAssertTrue(result.output.contains("d subdir"))
    }

    func testListSpecificPath() async {
        let subdir = "\(tempDir!)/nested"
        try? FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        try? "nested".write(toFile: "\(subdir)/inside.txt", atomically: true, encoding: .utf8)

        let tool = ListTool()
        let result = await tool.execute(arguments: "{\"path\":\"nested\"}", cwd: tempDir, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("inside.txt"))
    }

    func testListEmptyDirectory() async {
        let emptyDir = "\(tempDir!)/empty"
        try? FileManager.default.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)

        let tool = ListTool()
        let result = await tool.execute(arguments: "{\"path\":\"empty\"}", cwd: tempDir, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("empty"))
    }

    func testListOutsideCwdRejected() async {
        let tool = ListTool()
        let result = await tool.execute(arguments: "{\"path\":\"../outside\"}", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("outside"))
    }

    func testListInvalidJson() async {
        let tool = ListTool()
        let result = await tool.execute(arguments: "bad json", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidJson"))
    }

    func testListUnknownField() async {
        let tool = ListTool()
        let result = await tool.execute(arguments: "{\"path\":\".\",\"extra\":1}", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("unknownField"))
        XCTAssertTrue(result.output.contains("$.extra"))
    }

    func testListInvalidPathType() async {
        let tool = ListTool()
        let result = await tool.execute(arguments: "{\"path\":123}", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidType"))
        XCTAssertTrue(result.output.contains("$.path"))
    }

    // MARK: - FindTool

    func testFindByPattern() async {
        try? "a".write(toFile: "\(tempDir!)/alpha.txt", atomically: true, encoding: .utf8)
        try? "b".write(toFile: "\(tempDir!)/beta.swift", atomically: true, encoding: .utf8)
        try? "c".write(toFile: "\(tempDir!)/gamma.txt", atomically: true, encoding: .utf8)

        let tool = FindTool()
        let result = await tool.execute(arguments: "{\"path\":\".\",\"namePattern\":\"*.txt\"}", cwd: tempDir, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("alpha.txt"))
        XCTAssertTrue(result.output.contains("gamma.txt"))
        XCTAssertFalse(result.output.contains("beta.swift"))
    }

    func testFindAllFiles() async {
        try? "a".write(toFile: "\(tempDir!)/a.txt", atomically: true, encoding: .utf8)
        try? "b".write(toFile: "\(tempDir!)/b.swift", atomically: true, encoding: .utf8)

        let tool = FindTool()
        let result = await tool.execute(arguments: "{\"path\":\".\",\"namePattern\":\"*\"}", cwd: tempDir, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("a.txt"))
        XCTAssertTrue(result.output.contains("b.swift"))
    }

    func testFindRecursive() async {
        let subdir = "\(tempDir!)/deep"
        try? FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        try? "deep".write(toFile: "\(subdir)/deep.txt", atomically: true, encoding: .utf8)

        let tool = FindTool()
        let result = await tool.execute(arguments: "{\"path\":\".\",\"namePattern\":\"*.txt\"}", cwd: tempDir, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("deep.txt"))
    }

    func testFindOutsideCwdRejected() async {
        let tool = FindTool()
        let result = await tool.execute(arguments: "{\"path\":\"../outside\",\"namePattern\":\"*\"}", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("outside"))
    }

    func testFindNonDirectoryPath() async throws {
        try? "file".write(toFile: "\(tempDir!)/file.txt", atomically: true, encoding: .utf8)

        let tool = FindTool()
        let result = await tool.execute(arguments: "{\"path\":\"file.txt\",\"namePattern\":\"*\"}", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("not a directory"))
    }

    func testFindMaxDepthLimit() async {
        // Create a deep directory structure
        var currentDir = tempDir!
        for i in 1...8 {
            currentDir = "\(currentDir)/level\(i)"
            try? FileManager.default.createDirectory(atPath: currentDir, withIntermediateDirectories: true)
            try? "file".write(toFile: "\(currentDir)/file.txt", atomically: true, encoding: .utf8)
        }

        let tool = FindTool(maxDepth: 3)
        let result = await tool.execute(arguments: "{\"path\":\".\",\"namePattern\":\"*.txt\"}", cwd: tempDir, cancellation: nil)

        XCTAssertFalse(result.isError)
        // Depth = number of relative path components:
        // level1/file.txt = 2, level1/level2/file.txt = 3, level1/level2/level3/file.txt = 4
        // With maxDepth=3, only level1 and level2 files should be found
        XCTAssertTrue(result.output.contains("level1"))
        XCTAssertTrue(result.output.contains("level2"))
        // Depth 3+ (level3/file.txt = 4 components) should not appear
        XCTAssertFalse(result.output.contains("level3"))
        XCTAssertFalse(result.output.contains("level8"))
    }

    func testFindMaxResultsLimit() async {
        // Create many files
        for i in 0..<5 {
            try? "file".write(toFile: "\(tempDir!)/file\(i).txt", atomically: true, encoding: .utf8)
        }

        let tool = FindTool(maxResults: 3)
        let result = await tool.execute(arguments: "{\"path\":\".\",\"namePattern\":\"*.txt\"}", cwd: tempDir, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("truncated"))
    }

    func testFindInvalidJson() async {
        let tool = FindTool()
        let result = await tool.execute(arguments: "bad json", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidJson"))
    }

    func testFindUnknownField() async {
        let tool = FindTool()
        let result = await tool.execute(arguments: "{\"path\":\".\",\"namePattern\":\"*\",\"extra\":1}", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("unknownField"))
        XCTAssertTrue(result.output.contains("$.extra"))
    }

    func testFindInvalidPathType() async {
        let tool = FindTool()
        let result = await tool.execute(arguments: "{\"path\":123}", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidType"))
        XCTAssertTrue(result.output.contains("$.path"))
    }

    // MARK: - GrepTool

    func testGrepInFile() async throws {
        let filePath = "\(tempDir!)/test.txt"
        try "hello world\nfoo bar\nhello again".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = GrepTool()
        let result = await tool.execute(arguments: "{\"path\":\"test.txt\",\"pattern\":\"hello\"}", cwd: tempDir, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("test.txt:1:hello world"))
        XCTAssertTrue(result.output.contains("test.txt:3:hello again"))
        XCTAssertFalse(result.output.contains("foo bar"))
    }

    func testGrepInDirectory() async throws {
        let subdir = "\(tempDir!)/src"
        try? FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        try "hello world".write(toFile: "\(subdir)/a.txt", atomically: true, encoding: .utf8)
        try "foo bar".write(toFile: "\(subdir)/b.txt", atomically: true, encoding: .utf8)

        let tool = GrepTool()
        let result = await tool.execute(arguments: "{\"path\":\"src\",\"pattern\":\"hello\"}", cwd: tempDir, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("hello"))
        XCTAssertFalse(result.output.contains("foo"))
    }

    func testGrepNoMatches() async throws {
        let filePath = "\(tempDir!)/test.txt"
        try "hello world".write(toFile: filePath, atomically: true, encoding: .utf8)

        let tool = GrepTool()
        let result = await tool.execute(arguments: "{\"path\":\"test.txt\",\"pattern\":\"nonexistent\"}", cwd: tempDir, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("no matches"))
    }

    func testGrepMissingArguments() async {
        let tool = GrepTool()
        let result = await tool.execute(arguments: "{\"path\":\"test.txt\"}", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("missingRequired"))
        XCTAssertTrue(result.output.contains("$.pattern"))
    }

    func testGrepInvalidJson() async {
        let tool = GrepTool()
        let result = await tool.execute(arguments: "not json", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidJson"))
    }

    func testGrepInvalidPathType() async {
        let tool = GrepTool()
        let result = await tool.execute(arguments: "{\"path\":123,\"pattern\":\"x\"}", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("invalidType"))
        XCTAssertTrue(result.output.contains("$.path"))
    }

    func testGrepUnknownField() async {
        let tool = GrepTool()
        let result = await tool.execute(arguments: "{\"path\":\"test.txt\",\"pattern\":\"x\",\"extra\":1}", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("unknownField"))
        XCTAssertTrue(result.output.contains("$.extra"))
    }

    func testGrepOutsideCwdRejected() async {
        let tool = GrepTool()
        let result = await tool.execute(arguments: "{\"path\":\"../outside\",\"pattern\":\"test\"}", cwd: tempDir, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("outside"))
    }

    func testGrepMaxResultsLimit() async throws {
        var content = ""
        for i in 1...10 {
            content += "hello line \(i)\n"
        }
        try content.write(toFile: "\(tempDir!)/test.txt", atomically: true, encoding: .utf8)

        let tool = GrepTool(maxResults: 5)
        let result = await tool.execute(arguments: "{\"path\":\"test.txt\",\"pattern\":\"hello\"}", cwd: tempDir, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("truncated"))
    }
}
