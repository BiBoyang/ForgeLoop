import Foundation
import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopDiagnostics
@testable import ForgeLoopEval

final class EvalCommandTests: XCTestCase {

    func testHelpReturnsTrue() async throws {
        let command = EvalCommand()
        let success = try await command.run(
            arguments: ["--help"],
            diagnostics: Diagnostics()
        )
        XCTAssertTrue(success)
    }

    func testUnknownSuiteThrows() async throws {
        let command = EvalCommand()
        do {
            _ = try await command.run(
                arguments: ["--suite", "UnknownSuite"],
                diagnostics: Diagnostics()
            )
            XCTFail("Expected unknownSuite error")
        } catch EvalCommandError.unknownSuite {
            // Expected.
        }
    }

    func testUnknownFormatThrows() async throws {
        let command = EvalCommand()
        do {
            _ = try await command.run(
                arguments: ["--format", "xml"],
                diagnostics: Diagnostics()
            )
            XCTFail("Expected unknownFormat error")
        } catch EvalCommandError.unknownFormat {
            // Expected.
        }
    }

    func testMissingOutputDirectoryThrows() async throws {
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)/report.md")
            .path
        let suite = BenchmarkSuite(name: "Empty", cases: [])
        let command = EvalCommand()

        do {
            _ = try await command.run(
                suite: suite,
                providerName: "faux",
                format: "markdown",
                outputPath: outputPath,
                diagnostics: Diagnostics()
            )
            XCTFail("Expected missingOutputDirectory error")
        } catch EvalCommandError.missingOutputDirectory {
            // Expected.
        }
    }

    func testRunSuiteWithFauxProviderWritesReport() async throws {
        let provider = FauxProvider(
            api: "faux",
            mode: .toolCall(
                name: "bash",
                arguments: #"{"command": "/usr/bin/touch", "args": ["created.txt"]}"#
            )
        )
        let sourceId = "eval-command-test-\(UUID().uuidString)"
        await APIRegistry.shared.register(provider, sourceId: sourceId)

        let suite = BenchmarkSuite(
            name: "Test",
            cases: [
                EvalCase(
                    id: "touch-file",
                    name: "Touch File",
                    description: "Agent creates a file.",
                    prompt: "Create created.txt",
                    initialFiles: [],
                    assertions: [.fileExists(path: "created.txt")],
                    timeout: .seconds(5),
                    tags: ["test"]
                )
            ]
        )

        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-command-test-\(UUID().uuidString).md")
            .path

        let command = EvalCommand()
        let success = try await command.run(
            suite: suite,
            providerName: "faux",
            format: "markdown",
            outputPath: outputPath,
            diagnostics: Diagnostics()
        )

        await APIRegistry.shared.unregisterSource(sourceId)

        XCTAssertTrue(success, "Expected the suite to pass")
        let report = try String(contentsOfFile: outputPath, encoding: .utf8)
        XCTAssertTrue(report.contains("touch-file"), "Report should include the case ID")
        XCTAssertTrue(report.contains("✅"), "Report should mark the case as passed")
    }
}
