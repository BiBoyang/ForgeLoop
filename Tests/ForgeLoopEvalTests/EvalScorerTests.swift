import Foundation
import XCTest
@testable import ForgeLoopEval

final class EvalScorerTests: XCTestCase {

    // MARK: - FileExistsScorer

    func testFileExistsPasses() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        try await workspace.write(EvalFile(path: "present.txt", content: "hi"))

        let scorer = FileExistsScorer()
        let result = await scorer.score(
            assertion: .fileExists(path: "present.txt"),
            workspace: workspace
        )

        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.message.contains("present.txt"))
    }

    func testFileExistsFails() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        let scorer = FileExistsScorer()
        let result = await scorer.score(
            assertion: .fileExists(path: "missing.txt"),
            workspace: workspace
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.message.contains("not found"))
    }

    // MARK: - FileContentScorer

    func testFileContainsPasses() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        try await workspace.write(EvalFile(path: "doc.txt", content: "hello world"))

        let scorer = FileContentScorer()
        let result = await scorer.score(
            assertion: .fileContains(path: "doc.txt", substring: "world"),
            workspace: workspace
        )

        XCTAssertTrue(result.passed)
    }

    func testFileContainsFails() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        try await workspace.write(EvalFile(path: "doc.txt", content: "hello world"))

        let scorer = FileContentScorer()
        let result = await scorer.score(
            assertion: .fileContains(path: "doc.txt", substring: "missing"),
            workspace: workspace
        )

        XCTAssertFalse(result.passed)
    }

    func testFileNotContainsPasses() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        try await workspace.write(EvalFile(path: "doc.txt", content: "hello world"))

        let scorer = FileContentScorer()
        let result = await scorer.score(
            assertion: .fileNotContains(path: "doc.txt", substring: "goodbye"),
            workspace: workspace
        )

        XCTAssertTrue(result.passed)
    }

    func testFileNotContainsFails() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        try await workspace.write(EvalFile(path: "doc.txt", content: "hello world"))

        let scorer = FileContentScorer()
        let result = await scorer.score(
            assertion: .fileNotContains(path: "doc.txt", substring: "world"),
            workspace: workspace
        )

        XCTAssertFalse(result.passed)
    }

    func testFileEqualsPasses() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        try await workspace.write(EvalFile(path: "doc.txt", content: "exact"))

        let scorer = FileContentScorer()
        let result = await scorer.score(
            assertion: .fileEquals(path: "doc.txt", expected: "exact"),
            workspace: workspace
        )

        XCTAssertTrue(result.passed)
    }

    func testFileEqualsFails() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        try await workspace.write(EvalFile(path: "doc.txt", content: "actual"))

        let scorer = FileContentScorer()
        let result = await scorer.score(
            assertion: .fileEquals(path: "doc.txt", expected: "expected"),
            workspace: workspace
        )

        XCTAssertFalse(result.passed)
    }

    // MARK: - CommandOutputScorer

    func testCommandSucceedsPasses() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        let scorer = CommandOutputScorer()
        let result = await scorer.score(
            assertion: .commandSucceeds(command: ["true"]),
            workspace: workspace
        )

        XCTAssertTrue(result.passed)
    }

    func testCommandSucceedsFails() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        let scorer = CommandOutputScorer()
        let result = await scorer.score(
            assertion: .commandSucceeds(command: ["false"]),
            workspace: workspace
        )

        XCTAssertFalse(result.passed)
    }

    func testCommandOutputContainsPasses() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        let scorer = CommandOutputScorer()
        let result = await scorer.score(
            assertion: .commandOutputContains(command: ["echo", "hello world"], substring: "hello"),
            workspace: workspace
        )

        XCTAssertTrue(result.passed)
    }

    func testCommandOutputContainsFails() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        let scorer = CommandOutputScorer()
        let result = await scorer.score(
            assertion: .commandOutputContains(command: ["echo", "hello world"], substring: "goodbye"),
            workspace: workspace
        )

        XCTAssertFalse(result.passed)
    }

    // MARK: - CompositeScorer dispatch

    func testCompositeScorerDispatchesToFirstMatchingScorer() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        let expected = AssertionResult(
            assertion: .fileExists(path: "x.txt"),
            passed: true,
            message: "mock"
        )
        let mock = MockScorer(
            canHandle: { assertion in
                if case .fileExists = assertion { return true }
                return false
            },
            result: expected
        )

        let composite = CompositeScorer(scorers: [mock])
        let result = await composite.score(
            assertion: .fileExists(path: "x.txt"),
            workspace: workspace
        )

        XCTAssertEqual(result, expected)
    }

    func testCompositeScorerReturnsUnsupportedWhenNoScorerMatches() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        let composite = CompositeScorer(scorers: [])
        let result = await composite.score(
            assertion: .fileExists(path: "x.txt"),
            workspace: workspace
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.message, "Unsupported assertion")
    }

    // MARK: - Path isolation

    func testScorerRejectsEscapingPath() async throws {
        let workspace = try await Workspace.makeTemporary(prefix: "EvalScorerTests")
        addTeardownBlock {
            try? await workspace.cleanup()
        }

        let scorer = FileExistsScorer()
        let result = await scorer.score(
            assertion: .fileExists(path: "../outside.txt"),
            workspace: workspace
        )

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.message.contains("Invalid path"))
    }
}

private struct MockScorer: EvalScorer {
    let canHandle: @Sendable (EvalAssertion) -> Bool
    let result: AssertionResult

    func canScore(_ assertion: EvalAssertion) -> Bool {
        canHandle(assertion)
    }

    func score(assertion: EvalAssertion, workspace: Workspace) async -> AssertionResult {
        result
    }
}
