import Foundation
import XCTest
@testable import ForgeLoopEval

final class EvalModelTests: XCTestCase {
    func testEvalCaseRoundTrip() throws {
        let evalCase = EvalCase(
            id: "create-readme",
            name: "Create README",
            description: "Agent creates a README file",
            prompt: "Create a README.md with project name 'Foo'",
            initialFiles: [EvalFile(path: "hint.txt", content: "Make it markdown.")],
            assertions: [
                .fileExists(path: "README.md"),
                .fileContains(path: "README.md", substring: "Foo")
            ],
            timeout: .seconds(30),
            tags: ["smoke", "file"]
        )

        let data = try JSONEncoder().encode(evalCase)
        let decoded = try JSONDecoder().decode(EvalCase.self, from: data)

        XCTAssertEqual(evalCase, decoded)
    }

    func testAllAssertionCasesRoundTrip() throws {
        let assertions: [EvalAssertion] = [
            .fileContains(path: "a.txt", substring: "hello"),
            .fileNotContains(path: "a.txt", substring: "goodbye"),
            .fileEquals(path: "b.txt", expected: "exact"),
            .fileExists(path: "c.txt"),
            .commandSucceeds(command: ["swift", "test"]),
            .commandOutputContains(command: ["cat", "a.txt"], substring: "hello")
        ]

        let data = try JSONEncoder().encode(assertions)
        let decoded = try JSONDecoder().decode([EvalAssertion].self, from: data)

        XCTAssertEqual(assertions, decoded)
    }

    func testEvalResultRoundTrip() throws {
        let result = EvalResult(
            caseID: "case-1",
            passed: true,
            score: 1.0,
            duration: .seconds(1),
            assertionResults: [
                AssertionResult(
                    assertion: .fileExists(path: "README.md"),
                    passed: true,
                    message: "File exists"
                )
            ]
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(EvalResult.self, from: data)

        XCTAssertEqual(result, decoded)
    }

    func testEvalConfigDefaults() {
        let config = EvalConfig()
        XCTAssertEqual(config.providerName, "faux")
        XCTAssertEqual(config.maxRetries, 0)
        XCTAssertEqual(config.defaultTimeout, .seconds(60))
    }
}
