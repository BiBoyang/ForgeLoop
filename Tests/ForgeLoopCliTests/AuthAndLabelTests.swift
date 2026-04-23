import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopCli

@MainActor
final class AuthAndLabelTests: XCTestCase {

    // MARK: - resolveAgentAuth priority: CLI override > store > default

    func testCLIOverrideTakesPrecedence() async throws {
        let resolved = try await resolveAgentAuth(modelOverride: "gpt-4o")
        XCTAssertEqual(resolved.model.id, "gpt-4o")
        XCTAssertEqual(resolved.model.name, "gpt-4o")
    }

    func testDefaultFallbackWhenNoOverrideAndNoStore() async throws {
        let tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forgeloop-auth-test-\(UUID().uuidString)")
            .appendingPathComponent("model.json")
        let resolved = try await resolveAgentAuth(
            modelOverride: nil,
            modelStore: ModelStore(fileURL: tempPath)
        )
        XCTAssertEqual(resolved.model.id, "faux-coding-model")
    }

    // MARK: - labelForModel

    func testLabelForDefaultModel() {
        let defaultModel = Model(
            id: "faux-coding-model",
            name: "Faux Coding Model",
            api: "faux",
            provider: "faux"
        )
        let label = labelForModel(defaultModel)
        XCTAssertTrue(label.contains("faux-coding-model"))
        XCTAssertTrue(label.contains("local scaffold"))
    }

    func testLabelForCustomModel() {
        let customModel = Model(
            id: "gpt-4o",
            name: "GPT-4o",
            api: "openai",
            provider: "openai"
        )
        let label = labelForModel(customModel)
        XCTAssertTrue(label.contains("GPT-4o"))
        XCTAssertTrue(label.contains("gpt-4o"))
    }

    // MARK: - /model switches state.model dynamically

    func testModelSwitchUpdatesAgentState() async throws {
        let agent = Agent(initialState: AgentInitialState(
            model: Model(id: "old-model", name: "Old", api: "faux", provider: "faux")
        ))
        let controller = PromptController(agent: agent)

        XCTAssertEqual(agent.state.model.id, "old-model")

        _ = try await controller.submit("/model new-model")

        XCTAssertEqual(agent.state.model.id, "new-model")
        XCTAssertEqual(agent.state.model.name, "new-model")
        // api/provider preserved from original
        XCTAssertEqual(agent.state.model.api, "faux")
        XCTAssertEqual(agent.state.model.provider, "faux")
    }

    func testLabelForModelReflectsSwitch() async throws {
        let agent = Agent(initialState: AgentInitialState(
            model: Model(id: "old-model", name: "Old", api: "faux", provider: "faux")
        ))
        let controller = PromptController(agent: agent)

        let oldLabel = labelForModel(agent.state.model)
        XCTAssertTrue(oldLabel.contains("old-model"))

        _ = try await controller.submit("/model gpt-4o")

        let newLabel = labelForModel(agent.state.model)
        XCTAssertTrue(newLabel.contains("gpt-4o"))
        XCTAssertFalse(newLabel.contains("old-model"))
    }

    // MARK: - STEP-027) Credential storage

    func testCredentialStoreSaveAndLoad() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("credentials.json")
        let store = CredentialStore(fileURL: fileURL)

        XCTAssertNil(store.load())

        store.save(apiKey: "sk-test-key-123")
        XCTAssertEqual(store.load(), "sk-test-key-123")

        // Overwrite
        store.save(apiKey: "sk-new-key-456")
        XCTAssertEqual(store.load(), "sk-new-key-456")
    }

    func testCredentialStoreClear() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("credentials.json")
        let store = CredentialStore(fileURL: fileURL)

        store.save(apiKey: "sk-test")
        XCTAssertNotNil(store.load())

        store.clear()
        XCTAssertNil(store.load())
    }

    func testResolveAuthWithStoredCredentials() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let modelURL = tempDir.appendingPathComponent("model.json")
        let credURL = tempDir.appendingPathComponent("credentials.json")

        let model = Model(id: "gpt-4o", name: "GPT-4o", api: "openai", provider: "openai")
        ModelStore(fileURL: modelURL).save(model)
        CredentialStore(fileURL: credURL).save(apiKey: "sk-test")

        let resolved = try await resolveAgentAuth(
            modelOverride: nil,
            modelStore: ModelStore(fileURL: modelURL),
            credentialStore: CredentialStore(fileURL: credURL)
        )

        XCTAssertEqual(resolved.model.id, "gpt-4o")
    }

    func testResolveAuthMissingCredentialsThrows() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let modelURL = tempDir.appendingPathComponent("model.json")
        let credURL = tempDir.appendingPathComponent("credentials.json")

        // Save an openai model but no credentials
        let model = Model(id: "gpt-4o", name: "GPT-4o", api: "openai", provider: "openai")
        ModelStore(fileURL: modelURL).save(model)

        do {
            _ = try await resolveAgentAuth(
                modelOverride: nil,
                modelStore: ModelStore(fileURL: modelURL),
                credentialStore: CredentialStore(fileURL: credURL),
                environment: [:] // isolate from host env
            )
            XCTFail("Expected missing credentials error")
        } catch {
            let description = "\(error)"
            XCTAssertTrue(description.contains("Missing API key"), "Error should be diagnostic: \(description)")
            XCTAssertTrue(description.contains("forgeloop login"), "Error should suggest login: \(description)")
        }
    }

    func testResolveAuthFauxModelDoesNotRequireCredentials() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let modelURL = tempDir.appendingPathComponent("model.json")
        let credURL = tempDir.appendingPathComponent("credentials.json")

        // faux model without credentials should work
        let model = Model(id: "faux-coding-model", name: "Faux", api: "faux", provider: "faux")
        ModelStore(fileURL: modelURL).save(model)

        let resolved = try await resolveAgentAuth(
            modelOverride: nil,
            modelStore: ModelStore(fileURL: modelURL),
            credentialStore: CredentialStore(fileURL: credURL)
        )

        XCTAssertEqual(resolved.model.id, "faux-coding-model")
    }

    // MARK: - STEP-027 regression) env fallback + blank stored key

    func testCredentialStoreRejectsBlankKey() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("credentials.json")
        let store = CredentialStore(fileURL: fileURL)

        store.save(apiKey: "   ")
        XCTAssertNil(store.load(), "Blank key should be rejected")

        store.save(apiKey: "valid")
        XCTAssertEqual(store.load(), "valid")

        // Overwrite valid with blank → clear
        store.save(apiKey: "  \n  ")
        XCTAssertNil(store.load(), "Blank overwrite should clear store")
    }

    func testCredentialStoreLoadTrimsWhitespace() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileURL = tempDir.appendingPathComponent("credentials.json")
        let store = CredentialStore(fileURL: fileURL)

        // Manually write untrimmed key to simulate legacy/buggy state
        let dict: [String: String] = ["apiKey": "  sk-key  "]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        try! data.write(to: fileURL)

        XCTAssertEqual(store.load(), "sk-key", "Load should trim whitespace")
    }
}
