import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent

final class PathGuardSymlinkTests: XCTestCase {
    private var tempDir: URL!
    private var externalDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        externalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: externalDir)
        super.tearDown()
    }

    func testSymlinkToOutsideRejectedByRead() async {
        let secret = externalDir.appendingPathComponent("secret.txt")
        try? "secret".write(to: secret, atomically: true, encoding: .utf8)

        let link = tempDir.appendingPathComponent("outside_link")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalDir)

        let tool = ReadTool()
        let result = await tool.execute(arguments: "{\"path\":\"outside_link/secret.txt\"}", cwd: tempDir.path, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("outside the working directory"), "Expected outsideCwd error, got: \(result.output)")
    }

    func testSymlinkToOutsideRejectedByList() async {
        let link = tempDir.appendingPathComponent("outside_link")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalDir)

        let tool = ListTool()
        let result = await tool.execute(arguments: "{\"path\":\"outside_link\"}", cwd: tempDir.path, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("outside the working directory"), "Expected outsideCwd error, got: \(result.output)")
    }

    func testSymlinkToOutsideRejectedByGrep() async {
        let secret = externalDir.appendingPathComponent("secret.txt")
        try? "secret".write(to: secret, atomically: true, encoding: .utf8)

        let link = tempDir.appendingPathComponent("outside_link")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalDir)

        let tool = GrepTool()
        let result = await tool.execute(arguments: "{\"path\":\"outside_link\",\"pattern\":\"secret\"}", cwd: tempDir.path, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("outside the working directory"), "Expected outsideCwd error, got: \(result.output)")
    }

    func testSymlinkToOutsideRejectedByFind() async {
        let link = tempDir.appendingPathComponent("outside_link")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalDir)

        let tool = FindTool()
        let result = await tool.execute(arguments: "{\"path\":\"outside_link\"}", cwd: tempDir.path, cancellation: nil)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("outside the working directory"), "Expected outsideCwd error, got: \(result.output)")
    }

    func testSymlinkInsideAllowed() async {
        let subdir = tempDir.appendingPathComponent("subdir")
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let file = subdir.appendingPathComponent("inside.txt")
        try? "inside".write(to: file, atomically: true, encoding: .utf8)

        let link = tempDir.appendingPathComponent("inside_link")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: subdir)

        let tool = ReadTool()
        let result = await tool.execute(arguments: "{\"path\":\"inside_link/inside.txt\"}", cwd: tempDir.path, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.output, "inside")
    }

    func testFindDoesNotFollowSymlinks() async {
        let realFile = tempDir.appendingPathComponent("real.txt")
        try? "real".write(to: realFile, atomically: true, encoding: .utf8)

        let externalFile = externalDir.appendingPathComponent("external.txt")
        try? "external".write(to: externalFile, atomically: true, encoding: .utf8)

        // Create a symlink inside cwd pointing to external directory.
        let link = tempDir.appendingPathComponent("outside_link")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalDir)

        let tool = FindTool()
        let result = await tool.execute(arguments: "{\"path\":\".\"}", cwd: tempDir.path, cancellation: nil)

        XCTAssertFalse(result.isError)
        XCTAssertFalse(result.output.contains("external.txt"), "Should not follow symlinks into external directory")
        XCTAssertTrue(result.output.contains("real.txt"), "Should still find real files inside cwd")
    }
}
