import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopCli

final class ModelStoreTests: XCTestCase {
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

    // MARK: - 1) Save and load round-trip

    func testSaveAndLoadRoundTrip() {
        let fileURL = tempDir.appendingPathComponent("model.json")
        let store = ModelStore(fileURL: fileURL)

        let model = Model(
            id: "gpt-4",
            name: "GPT-4",
            api: "openai",
            provider: "openai",
            baseUrl: "https://api.openai.com"
        )
        store.save(model)

        let loaded = store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, "gpt-4")
        XCTAssertEqual(loaded?.name, "GPT-4")
        XCTAssertEqual(loaded?.api, "openai")
        XCTAssertEqual(loaded?.provider, "openai")
        XCTAssertEqual(loaded?.baseUrl, "https://api.openai.com")
    }

    // MARK: - 2) Load from missing file returns nil

    func testLoadMissingFileReturnsNil() {
        let fileURL = tempDir.appendingPathComponent("nonexistent.json")
        let store = ModelStore(fileURL: fileURL)
        XCTAssertNil(store.load())
    }

    // MARK: - 3) Load from corrupt JSON returns nil (graceful fallback)

    func testLoadCorruptJSONReturnsNil() {
        let fileURL = tempDir.appendingPathComponent("model.json")
        try? "not json".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = ModelStore(fileURL: fileURL)
        XCTAssertNil(store.load())
    }

    // MARK: - 4) Load from partial JSON returns nil

    func testLoadPartialJSONReturnsNil() {
        let fileURL = tempDir.appendingPathComponent("model.json")
        try? "{\"id\": \"gpt-4\"}".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = ModelStore(fileURL: fileURL)
        XCTAssertNil(store.load())
    }

    // MARK: - 5) Clear removes the file

    func testClearRemovesFile() {
        let fileURL = tempDir.appendingPathComponent("model.json")
        let store = ModelStore(fileURL: fileURL)

        let model = Model(id: "test", name: "Test", api: "faux", provider: "faux")
        store.save(model)
        XCTAssertNotNil(store.load())

        store.clear()
        XCTAssertNil(store.load())
    }

    // MARK: - 6) Overwrite existing file

    func testOverwriteExistingFile() {
        let fileURL = tempDir.appendingPathComponent("model.json")
        let store = ModelStore(fileURL: fileURL)

        let model1 = Model(id: "model-a", name: "A", api: "faux", provider: "faux")
        store.save(model1)

        let model2 = Model(id: "model-b", name: "B", api: "openai", provider: "openai")
        store.save(model2)

        let loaded = store.load()
        XCTAssertEqual(loaded?.id, "model-b")
        XCTAssertEqual(loaded?.api, "openai")
    }
}
