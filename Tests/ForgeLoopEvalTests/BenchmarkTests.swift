import Foundation
import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopEval

final class BenchmarkTests: XCTestCase {

    /// Runs every case in `Suite1` with a deterministic `FauxProvider` and
    /// verifies that the runner reports all assertions passed. Results are also
    /// fed through `JSONEvalReporter` and `MarkdownEvalReporter` to exercise the
    /// full EvalRunner + EvalScorer + EvalReporter pipeline.
    func testSuite1AllPass() async throws {
        var results: [EvalResult] = []

        for evalCase in BenchmarkSuites.suite1.cases {
            let sourceId = "benchmark-suite1-\(evalCase.id)-\(UUID().uuidString)"
            let provider = makeProvider(for: evalCase)
            await APIRegistry.shared.register(provider, sourceId: sourceId)

            let runner = EvalRunner(config: EvalConfig(providerName: "faux"))
            let result = await runner.run(evalCase)

            await APIRegistry.shared.unregisterSource(sourceId)

            XCTAssertTrue(
                result.passed,
                "Case \(evalCase.id) failed: \(result.assertionResults)"
            )
            results.append(result)
        }

        let json = try await JSONEvalReporter().report(results: results)
        XCTAssertTrue(json.contains("\"totalCases\" : 3"), "JSON report should summarize 3 cases")

        let markdown = try await MarkdownEvalReporter().report(results: results)
        XCTAssertTrue(markdown.contains("suite1-create-readme"), "Markdown report should list case details")
    }

    private func makeProvider(for evalCase: EvalCase) -> FauxProvider {
        switch evalCase.id {
        case "suite1-create-readme":
            return FauxProvider(
                api: "faux",
                mode: .toolCall(
                    name: "bash",
                    arguments: #"{"command": "/bin/sh", "args": ["-c", "printf '# Foo\n\nProject Foo.' > README.md"]}"#
                )
            )
        case "suite1-add-function":
            return FauxProvider(
                api: "faux",
                mode: .toolCall(
                    name: "bash",
                    arguments: #"{"command": "/bin/sh", "args": ["-c", "printf 'func sum(_ a: Int, _ b: Int) -> Int {\n    return a + b\n}\n' > Math.swift"]}"#
                )
            )
        case "suite1-fix-typo":
            return FauxProvider(
                api: "faux",
                mode: .toolCall(
                    name: "edit",
                    arguments: #"{"path": "greeting.txt", "oldText": "Helo", "newText": "Hello"}"#
                )
            )
        default:
            return FauxProvider(api: "faux")
        }
    }
}
