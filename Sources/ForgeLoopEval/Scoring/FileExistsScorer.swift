import Foundation

/// Scores `fileExists` assertions by checking the workspace for the given path.
public struct FileExistsScorer: EvalScorer {
    public init() {}

    public func canScore(_ assertion: EvalAssertion) -> Bool {
        if case .fileExists = assertion { return true }
        return false
    }

    public func score(assertion: EvalAssertion, workspace: Workspace) async -> AssertionResult {
        guard case .fileExists(let path) = assertion else {
            return AssertionResult(
                assertion: assertion,
                passed: false,
                message: "Unsupported assertion"
            )
        }

        do {
            let url = try await workspace.resolvedURL(for: path)
            let exists = FileManager.default.fileExists(atPath: url.path)
            return AssertionResult(
                assertion: assertion,
                passed: exists,
                message: exists ? "File exists: \(path)" : "File not found: \(path)"
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
