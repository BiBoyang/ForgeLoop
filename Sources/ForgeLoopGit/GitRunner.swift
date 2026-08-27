// Inspired by termio (MIT): https://github.com/termio-sh/termio
import Foundation

/// The captured result of one `git` invocation.
struct GitOutput: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

/// Minimal `/usr/bin/git` process runner, private to ForgeLoopGit on purpose:
/// layering rules forbid borrowing ForgeLoopAgent's ProcessRunner.
enum GitRunner {
    /// The environment for every git subprocess. `GIT_OPTIONAL_LOCKS=0` keeps
    /// read-only commands (notably `git status`) from taking the index lock and
    /// rewriting `.git/index`, which would otherwise loop any file-system watcher
    /// observing `.git`. Safe for writes: only *optional* locks are skipped.
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }

    /// Runs `git -C <directory> <args>` to completion, returning raw output.
    /// Throws only when the process cannot be launched; a non-zero exit is
    /// reported in the result, not thrown.
    static func git(_ arguments: [String], in directory: URL) throws -> GitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw GitError.gitUnavailable
        }
        // stdout is drained first, so git never blocks on a full stdout pipe. stderr
        // is drained after; git's own error output is small enough to fit the pipe
        // buffer while the process runs.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitOutput(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Runs git and throws `GitError.commandFailed` on a non-zero exit.
    @discardableResult
    static func run(_ arguments: [String], in directory: URL) throws -> GitOutput {
        let output = try git(arguments, in: directory)
        guard output.exitCode == 0 else {
            throw GitError.commandFailed(
                arguments: arguments,
                exitCode: output.exitCode,
                stderr: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }

    /// Maps the two "not a usable repository" shapes onto dedicated errors:
    /// a missing path, and an existing path git knows nothing about.
    static func validateRepository(_ repository: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repository.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GitError.repositoryNotFound(path: repository.path)
        }
        let output = try git(["rev-parse", "--is-inside-work-tree"], in: repository)
        guard output.exitCode == 0,
              output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw GitError.notARepository(path: repository.path)
        }
    }

    /// Runs blocking git work off the cooperative thread pool: `waitUntilExit`
    /// must never park a Swift concurrency executor thread.
    static func offThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result(catching: work))
            }
        }
    }
}
