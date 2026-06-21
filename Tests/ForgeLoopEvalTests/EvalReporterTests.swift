import Foundation
import XCTest
@testable import ForgeLoopEval

final class EvalReporterTests: XCTestCase {

    // MARK: - JSON report

    func testJSONReportContainsSummaryAndResults() async throws {
        let reporter = JSONEvalReporter()
        let results = sampleResults()
        let json = try await reporter.report(results: results)

        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(EvalReport.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, "1.0")
        XCTAssertFalse(decoded.generatedAt.isEmpty)
        XCTAssertEqual(decoded.summary.totalCases, 3)
        XCTAssertEqual(decoded.summary.passedCases, 2)
        XCTAssertEqual(decoded.summary.failedCases, 1)
        XCTAssertEqual(decoded.results.count, 3)

        let passing = try XCTUnwrap(decoded.results.first { $0.caseID == "passing-case" })
        XCTAssertTrue(passing.passed)
        XCTAssertEqual(passing.score, 1.0)
        XCTAssertEqual(passing.durationMs, 1500)

        let failing = try XCTUnwrap(decoded.results.first { $0.caseID == "failing-case" })
        XCTAssertFalse(failing.passed)
        XCTAssertEqual(failing.assertionResults.count, 1)
        XCTAssertFalse(failing.assertionResults[0].passed)
    }

    func testJSONReportHandlesEmptyResults() async throws {
        let reporter = JSONEvalReporter()
        let json = try await reporter.report(results: [])

        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(EvalReport.self, from: data)

        XCTAssertEqual(decoded.summary.totalCases, 0)
        XCTAssertEqual(decoded.summary.passedCases, 0)
        XCTAssertEqual(decoded.summary.failedCases, 0)
        XCTAssertEqual(decoded.summary.averageScore, 0.0)
        XCTAssertEqual(decoded.summary.averageDurationMs, 0)
        XCTAssertTrue(decoded.results.isEmpty)
    }

    func testJSONDurationsAreInMilliseconds() async throws {
        let reporter = JSONEvalReporter()
        let results = [
            EvalResult(
                caseID: "duration-case",
                passed: true,
                score: 1.0,
                duration: .seconds(2) + .milliseconds(500),
                assertionResults: []
            )
        ]
        let json = try await reporter.report(results: results)

        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(EvalReport.self, from: data)

        XCTAssertEqual(decoded.results[0].durationMs, 2500)
    }

    // MARK: - Markdown report

    func testMarkdownReportContainsSummary() async throws {
        let reporter = MarkdownEvalReporter()
        let results = sampleResults()
        let markdown = try await reporter.report(results: results)

        XCTAssertTrue(markdown.contains("# ForgeLoop Eval Report"))
        XCTAssertTrue(markdown.contains("## Summary"))
        XCTAssertTrue(markdown.contains("| 3 "))
        XCTAssertTrue(markdown.contains("| 2 "))
        XCTAssertTrue(markdown.contains("| 1 "))
    }

    func testMarkdownReportContainsFailureDetails() async throws {
        let reporter = MarkdownEvalReporter()
        let results = sampleResults()
        let markdown = try await reporter.report(results: results)

        XCTAssertTrue(markdown.contains("## Failures"))
        XCTAssertTrue(markdown.contains("### failing-case"))
        XCTAssertTrue(markdown.contains("does not contain"))
    }

    func testMarkdownReportHandlesEmptyResults() async throws {
        let reporter = MarkdownEvalReporter()
        let markdown = try await reporter.report(results: [])

        XCTAssertTrue(markdown.contains("No cases were run."))
        XCTAssertFalse(markdown.contains("## Failures"))
    }

    func testMarkdownReportHandlesAllPass() async throws {
        let reporter = MarkdownEvalReporter()
        let results = [
            EvalResult(
                caseID: "all-pass",
                passed: true,
                score: 1.0,
                duration: .seconds(1),
                assertionResults: [
                    AssertionResult(
                        assertion: .fileExists(path: "x.txt"),
                        passed: true,
                        message: "ok"
                    )
                ]
            )
        ]
        let markdown = try await reporter.report(results: results)

        XCTAssertTrue(markdown.contains("## Details"))
        XCTAssertFalse(markdown.contains("## Failures"))
    }

    // MARK: - Helpers

    private func sampleResults() -> [EvalResult] {
        [
            EvalResult(
                caseID: "passing-case",
                passed: true,
                score: 1.0,
                duration: .seconds(1) + .milliseconds(500),
                assertionResults: [
                    AssertionResult(
                        assertion: .fileExists(path: "a.txt"),
                        passed: true,
                        message: "File exists: a.txt"
                    )
                ]
            ),
            EvalResult(
                caseID: "another-pass",
                passed: true,
                score: 1.0,
                duration: .seconds(2),
                assertionResults: []
            ),
            EvalResult(
                caseID: "failing-case",
                passed: false,
                score: 0.0,
                duration: .milliseconds(800),
                assertionResults: [
                    AssertionResult(
                        assertion: .fileContains(path: "b.txt", substring: "hello"),
                        passed: false,
                        message: "File b.txt does not contain 'hello'"
                    )
                ]
            )
        ]
    }
}
