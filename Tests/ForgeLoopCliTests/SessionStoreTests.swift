import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopCli

final class SessionStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Save and load round-trip

    func testSaveAndLoadRoundtrip() throws {
        let store = SessionStore(directoryURL: tempDir)
        let messages: [Message] = [
            .user(UserMessage(text: "hello")),
            .assistant(AssistantMessage.text("hi there")),
            .tool(ToolResultMessage(toolCallId: "call-1", output: "result", isError: false))
        ]

        try store.save(name: "test", modelID: "gpt-4", messages: messages)

        let loaded = try store.load(name: "test")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.modelID, "gpt-4")
        XCTAssertEqual(loaded?.messages.count, 3)
        XCTAssertEqual(loaded?.messageCount, 3)
        XCTAssertEqual(loaded?.messages[0], .user(UserMessage(text: "hello")))
        XCTAssertEqual(loaded?.messages[1], .assistant(AssistantMessage.text("hi there")))
        XCTAssertEqual(loaded?.messages[2], .tool(ToolResultMessage(toolCallId: "call-1", output: "result", isError: false)))
    }

    // MARK: - List saved sessions

    func testListReturnsSavedSessions() throws {
        let store = SessionStore(directoryURL: tempDir)
        try store.save(name: "alpha", modelID: "gpt-4", messages: [.user(UserMessage(text: "a"))])
        try store.save(name: "beta", modelID: "gpt-4o", messages: [.user(UserMessage(text: "b"))])

        let list = try store.list()
        XCTAssertEqual(list, ["alpha", "beta"])
    }

    // MARK: - Delete session

    func testDeleteRemovesSession() throws {
        let store = SessionStore(directoryURL: tempDir)
        try store.save(name: "delete-me", modelID: "gpt-4", messages: [.user(UserMessage(text: "x"))])
        XCTAssertEqual(try store.list(), ["delete-me"])

        let deleted = try store.delete(name: "delete-me")
        XCTAssertTrue(deleted)
        XCTAssertTrue(try store.list().isEmpty)
    }

    // MARK: - Load non-existent session returns nil

    func testLoadNonExistentReturnsNil() throws {
        let store = SessionStore(directoryURL: tempDir)
        let loaded = try store.load(name: "missing")
        XCTAssertNil(loaded)
    }

    // MARK: - Delete non-existent session returns false

    func testDeleteNonExistentReturnsFalse() throws {
        let store = SessionStore(directoryURL: tempDir)
        let deleted = try store.delete(name: "missing")
        XCTAssertFalse(deleted)
    }

    // MARK: - Empty messages do not throw

    func testEmptyMessagesDoesNotThrow() throws {
        let store = SessionStore(directoryURL: tempDir)
        XCTAssertNoThrow(try store.save(name: "empty", modelID: "gpt-4", messages: []))

        let loaded = try store.load(name: "empty")
        XCTAssertNotNil(loaded)
        XCTAssertTrue(loaded?.messages.isEmpty ?? false)
        XCTAssertEqual(loaded?.messageCount, 0)
    }

    // MARK: - Path traversal protection

    func testSaveWithDotDotNameThrows() throws {
        let store = SessionStore(directoryURL: tempDir)
        XCTAssertThrowsError(try store.save(name: "../evil", modelID: "gpt-4", messages: [])) { error in
            XCTAssertTrue("\(error)".contains("Invalid session name"))
        }
    }

    func testSaveWithSlashNameThrows() throws {
        let store = SessionStore(directoryURL: tempDir)
        XCTAssertThrowsError(try store.save(name: "foo/bar", modelID: "gpt-4", messages: [])) { error in
            XCTAssertTrue("\(error)".contains("Invalid session name"))
        }
    }

    func testSaveWithHiddenNameThrows() throws {
        let store = SessionStore(directoryURL: tempDir)
        XCTAssertThrowsError(try store.save(name: ".hidden", modelID: "gpt-4", messages: [])) { error in
            XCTAssertTrue("\(error)".contains("Invalid session name"))
        }
    }

    func testLoadWithDotDotNameThrows() throws {
        let store = SessionStore(directoryURL: tempDir)
        XCTAssertThrowsError(try store.load(name: "../evil")) { error in
            XCTAssertTrue("\(error)".contains("Invalid session name"))
        }
    }

    func testDeleteWithDotDotNameThrows() throws {
        let store = SessionStore(directoryURL: tempDir)
        XCTAssertThrowsError(try store.delete(name: "../evil")) { error in
            XCTAssertTrue("\(error)".contains("Invalid session name"))
        }
    }

    // MARK: - File permissions

    func testSavedSessionFileHasRestrictedPermissions() throws {
        let store = SessionStore(directoryURL: tempDir)
        try store.save(name: "secure", modelID: "gpt-4", messages: [.user(UserMessage(text: "x"))])

        let fileURL = tempDir.appendingPathComponent("secure.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600, "Session file should be owner-only")
    }
}
