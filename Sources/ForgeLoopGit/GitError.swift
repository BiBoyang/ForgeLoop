import Foundation

/// Structured failure of a `ForgeLoopGit` operation — never a bare string.
public enum GitError: Error, Sendable, Equatable {
    /// `/usr/bin/git` could not be launched at all.
    case gitUnavailable
    /// The path does not exist or is not a directory.
    case repositoryNotFound(path: String)
    /// The path exists but is not inside a git work tree.
    case notARepository(path: String)
    /// git exited non-zero; `stderr` carries git's own message.
    case commandFailed(arguments: [String], exitCode: Int32, stderr: String)
}

extension GitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .gitUnavailable:
            return "git is not available at /usr/bin/git"
        case .repositoryNotFound(let path):
            return "repository path does not exist: \(path)"
        case .notARepository(let path):
            return "not a git repository: \(path)"
        case .commandFailed(let arguments, let exitCode, let stderr):
            let command = (["git"] + arguments).joined(separator: " ")
            return "\(command) failed (exit \(exitCode)): \(stderr)"
        }
    }
}
