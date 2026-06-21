import Foundation
import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopEval

final class EvalRunnerTests: XCTestCase {
    private var registeredSource: String?

    override func setUp() async throws {
        try await super.setUp()
        let sourceId = "eval-runner-tests-\(UUID().uuidString)"
        registeredSource = sourceId
        _ = await registerBuiltins(sourceId: sourceId)
    }

    override func tearDown() async throws {
        if let sourceId = registeredSource {
            await APIRegistry.shared.unregisterSource(sourceId)
        }
        try await super.tearDown()
    }

    // MARK: - Workspace isolation

    func testWorkspaceIsolation() async throws {
        let workspaceA = try await Workspace.makeTemporary(prefix: "EvalRunnerTests-A")
        let workspaceB = try await Workspace.makeTemporary(prefix: "EvalRunnerTests-B")

        defer {
            Task {
                try? await workspaceA.cleanup()
                try? await workspaceB.cleanup()
            }
        }

        try await workspaceA.write(EvalFile(path: "file.txt", content: "A"))
        try await workspaceB.write(EvalFile(path: "file.txt", content: "B"))

        let rootA = await workspaceA.rootURL
        let rootB = await workspaceB.rootURL
        XCTAssertNotEqual(rootA, rootB)

        let contentA = try String(contentsOf: rootA.appendingPathComponent("file.txt"), encoding: .utf8)
        let contentB = try String(contentsOf: rootB.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(contentA, "A")
        XCTAssertEqual(contentB, "B")

        // Both roots must live under the system temporary directory.
        let tempDir = FileManager.default.temporaryDirectory.standardizedFileURL
        XCTAssertTrue(rootA.standardizedFileURL.path.hasPrefix(tempDir.path))
        XCTAssertTrue(rootB.standardizedFileURL.path.hasPrefix(tempDir.path))
    }

    func testWorkspaceRejectsPathsOutsideTemporaryDirectory() async throws {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertThrowsError(try Workspace(rootURL: homeURL)) { error in
            guard case WorkspaceError.notUnderTemporaryDirectory = error else {
                XCTFail("Expected notUnderTemporaryDirectory error, got \(error)")
                return
            }
        }
    }

    func testWorkspaceRejectsEscapingPaths() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalRunnerTests-Escape")
        defer {
            Task {
                try? await workspace.cleanup()
            }
        }

        do {
            try await workspace.write(EvalFile(path: "../outside.txt", content: "x"))
            XCTFail("Expected write to throw WorkspaceError.invalidPath")
        } catch WorkspaceError.invalidPath {
            // Expected.
        } catch {
            XCTFail("Expected invalidPath error, got \(error)")
        }
    }

    // MARK: - AgentDriver / EvalRunner integration

    func testFauxProviderCreatesFileWithBash() async throws {
        let provider = FauxProvider(
            api: "faux",
            mode: .toolCall(
                name: "bash",
                arguments: #"{"command": "/usr/bin/touch", "args": ["created.txt"]}"#
            )
        )
        let sourceId = "eval-runner-faux-touch-\(UUID().uuidString)"
        await APIRegistry.shared.register(provider, sourceId: sourceId)
        defer {
            Task {
                await APIRegistry.shared.unregisterSource(sourceId)
            }
        }

        let evalCase = EvalCase(
            id: "faux-touch-file",
            name: "Faux Touch File",
            description: "Agent uses bash to create a file",
            prompt: "Create a file named created.txt",
            initialFiles: [],
            assertions: [
                .fileExists(path: "created.txt")
            ],
            timeout: .seconds(10)
        )

        let runner = EvalRunner(config: EvalConfig(providerName: "faux"))
        let result = await runner.run(evalCase)

        XCTAssertFalse(result.assertionResults.isEmpty)
        for assertionResult in result.assertionResults {
            XCTAssertTrue(assertionResult.passed, assertionResult.message)
        }
        XCTAssertTrue(result.passed, "Expected eval to pass, got \(result)")
    }
}
