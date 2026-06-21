import Foundation

/// Scores file-content assertions: `fileContains`, `fileNotContains`, and
/// `fileEquals`.
public struct FileContentScorer: EvalScorer {
    private let textMatcher = TextMatchScorer()

    public init() {}

    public func canScore(_ assertion: EvalAssertion) -> Bool {
        switch assertion {
        case .fileContains, .fileNotContains, .fileEquals:
            return true
        default:
            return false
        }
    }

    public func score(assertion: EvalAssertion, workspace: Workspace) async -> AssertionResult {
        switch assertion {
        case .fileContains(let path, let substring):
            return await scoreFileContains(
                path: path,
                substring: substring,
                assertion: assertion,
                workspace: workspace
            )
        case .fileNotContains(let path, let substring):
            return await scoreFileNotContains(
                path: path,
                substring: substring,
                assertion: assertion,
                workspace: workspace
            )
        case .fileEquals(let path, let expected):
            return await scoreFileEquals(
                path: path,
                expected: expected,
                assertion: assertion,
                workspace: workspace
            )
        default:
            return AssertionResult(
                assertion: assertion,
                passed: false,
                message: "Unsupported assertion"
            )
        }
    }

    private func scoreFileContains(
        path: String,
        substring: String,
        assertion: EvalAssertion,
        workspace: Workspace
    ) async -> AssertionResult {
        do {
            let url = try await workspace.resolvedURL(for: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return AssertionResult(
                    assertion: assertion,
                    passed: false,
                    message: "File not found: \(path)"
                )
            }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                return AssertionResult(
                    assertion: assertion,
                    passed: false,
                    message: "Could not read file: \(path)"
                )
            }
            let passed = textMatcher.contains(content, substring: substring)
            return AssertionResult(
                assertion: assertion,
                passed: passed,
                message: passed
                    ? "File \(path) contains '\(substring)'"
                    : "File \(path) does not contain '\(substring)'"
            )
        } catch {
            return AssertionResult(
                assertion: assertion,
                passed: false,
                message: "Invalid path '\(path)': \(error.localizedDescription)"
            )
        }
    }

    private func scoreFileNotContains(
        path: String,
        substring: String,
        assertion: EvalAssertion,
        workspace: Workspace
    ) async -> AssertionResult {
        do {
            let url = try await workspace.resolvedURL(for: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return AssertionResult(
                    assertion: assertion,
                    passed: false,
                    message: "File not found: \(path)"
                )
            }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                return AssertionResult(
                    assertion: assertion,
                    passed: false,
                    message: "Could not read file: \(path)"
                )
            }
            let passed = textMatcher.notContains(content, substring: substring)
            return AssertionResult(
                assertion: assertion,
                passed: passed,
                message: passed
                    ? "File \(path) does not contain '\(substring)'"
                    : "File \(path) contains '\(substring)'"
            )
        } catch {
            return AssertionResult(
                assertion: assertion,
                passed: false,
                message: "Invalid path '\(path)': \(error.localizedDescription)"
            )
        }
    }

    private func scoreFileEquals(
        path: String,
        expected: String,
        assertion: EvalAssertion,
        workspace: Workspace
    ) async -> AssertionResult {
        do {
            let url = try await workspace.resolvedURL(for: path)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                return AssertionResult(
                    assertion: assertion,
                    passed: false,
                    message: "Could not read file: \(path)"
                )
            }
            let passed = textMatcher.equals(content, expected: expected)
            return AssertionResult(
                assertion: assertion,
                passed: passed,
                message: passed
                    ? "File \(path) matches expected content"
                    : "File \(path) does not match expected content"
            )
        } catch {
            return AssertionResult(
                assertion: assertion,
                passed: false,
                message: "Invalid path '\(path)': \(error.localizedDescription)"
            )
        }
    }
}
