import Foundation
import XCTest
@testable import ForgeLoopEval

final class BenchmarkTests: XCTestCase {

    /// Runs every case in `Suite1` with the deterministic runner and verifies
    /// that all assertions passed. Results are also fed through
    /// `JSONEvalReporter` and `MarkdownEvalReporter` to exercise the full
    /// EvalRunner + EvalScorer + EvalReporter pipeline.
    func testSuite1AllPass() async throws {
        let results = await DeterministicRunner().run(BenchmarkSuites.suite1)

        for result in results {
            XCTAssertTrue(
                result.passed,
                "Case \(result.caseID) failed: \(result.assertionResults)"
            )
        }

        let json = try await JSONEvalReporter().report(results: results)
        XCTAssertTrue(json.contains("\"totalCases\" : 3"), "JSON report should summarize 3 cases")

        let markdown = try await MarkdownEvalReporter().report(results: results)
        XCTAssertTrue(markdown.contains("suite1-create-readme"), "Markdown report should list case details")
    }
}
