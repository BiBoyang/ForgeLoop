// Inspired by termio (MIT): https://github.com/termio-sh/termio
import Foundation

/// Thin async wrapper over the `git` CLI for one repository: status, history,
/// diff, and the current branch. Stateless by design — every call re-runs git,
/// whose output is the only source of truth.
public struct GitService: Sendable {
    public let repository: URL

    public init(repository: URL) {
        self.repository = repository
    }

    /// Staged, unstaged, and untracked changes, parsed from
    /// `git status --porcelain=v2 -z --untracked-files=all`.
    public func status() async throws -> GitStatus {
        try await GitRunner.offThread {
            try GitRunner.validateRepository(repository)
            let output = try GitRunner.run(
                ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
                in: repository
            )
            return Self.parseStatus(output.stdout)
        }
    }

    /// Recent commits on the current branch, newest first. A repository with no
    /// commits yet yields an empty list rather than an error.
    public func log(limit: Int = 100) async throws -> [GitCommit] {
        try await GitRunner.offThread {
            try GitRunner.validateRepository(repository)
            // Fields joined by US, records by RS, so subjects with spaces or tabs
            // survive intact.
            let format = ["%H", "%h", "%s", "%an", "%ae", "%ad"].joined(separator: "\u{1f}") + "\u{1e}"
            do {
                let output = try GitRunner.run(
                    ["log", "-n", String(limit), "--date=iso-strict", "--pretty=format:\(format)"],
                    in: repository
                )
                return Self.parseLog(output.stdout)
            } catch let error as GitError {
                // `git log` exits 128 on a branch with no commits — that is a
                // legitimate empty history, not a failure.
                if case .commandFailed(_, _, let stderr) = error,
                   stderr.contains("does not have any commits") {
                    return []
                }
                throw error
            }
        }
    }

    /// The unified-diff text of the working tree against the index, or of the
    /// index against HEAD when `staged` is true; optionally limited to one
    /// repo-relative path. Untracked files have no diff here — they are whole-file
    /// additions by definition.
    public func diff(path: String? = nil, staged: Bool = false) async throws -> String {
        try await GitRunner.offThread {
            try GitRunner.validateRepository(repository)
            var arguments = ["diff"]
            if staged { arguments.append("--cached") }
            arguments.append("--")
            if let path { arguments.append(path) }
            return try GitRunner.run(arguments, in: repository).stdout
        }
    }

    /// The current branch name, or `nil` on a detached HEAD.
    public func currentBranch() async throws -> String? {
        try await GitRunner.offThread {
            try GitRunner.validateRepository(repository)
            let output = try GitRunner.run(["rev-parse", "--abbrev-ref", "HEAD"], in: repository)
            let name = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name.isEmpty || name == "HEAD") ? nil : name
        }
    }

    /// The unified-diff text of one commit, without the commit header
    /// (`git show --format= -M --first-parent`). `--first-parent` keeps a merge
    /// commit's diff non-empty by diffing against the branch that was merged into.
    public func commitDiff(_ sha: String) async throws -> String {
        try await GitRunner.offThread {
            try GitRunner.validateRepository(repository)
            return try GitRunner.run(
                ["show", "--format=", "-M", "--first-parent", sha],
                in: repository
            ).stdout
        }
    }

    // MARK: - Parsing

    /// Parses `git status --porcelain=v2 -z`. Records are NUL-separated; the path
    /// is always the *current* path, so renames (type `2`) carry the original path
    /// in the following NUL field. The index side (`X`) and the worktree side (`Y`)
    /// of the `XY` field are split into the staged and unstaged lists.
    static func parseStatus(_ raw: String) -> GitStatus {
        var status = GitStatus()
        let tokens = raw.components(separatedBy: "\0").filter { !$0.isEmpty }
        var index = 0
        while index < tokens.count {
            let record = tokens[index]
            index += 1
            guard let kind = record.first else { continue }
            switch kind {
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                appendTracked(xy: Array(fields[1]), path: String(fields[8]), into: &status)
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10 else { continue }
                var originalPath: String?
                if index < tokens.count {
                    originalPath = tokens[index]
                    index += 1
                }
                appendTracked(xy: Array(fields[1]), path: String(fields[9]),
                              originalPath: originalPath, into: &status)
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                status.unstaged.append(
                    GitChange(path: String(fields[10]), status: .conflicted, isUntracked: false))
            case "?":
                let path = String(record.dropFirst(2))
                status.untracked.append(GitChange(path: path, status: .untracked, isUntracked: true))
            default:
                continue // "!" ignored entries
            }
        }
        return status
    }

    /// Splits a porcelain-v2 `XY` field (where `.` means unmodified) into the
    /// staged and unstaged change lists.
    private static func appendTracked(
        xy: [Character], path: String, originalPath: String? = nil, into status: inout GitStatus
    ) {
        let indexCode = xy.first ?? "."
        let worktreeCode = xy.count > 1 ? xy[1] : "."
        if indexCode != "." {
            status.staged.append(GitChange(
                path: path, status: GitFileStatus(code: indexCode),
                isUntracked: false, originalPath: originalPath))
        }
        if worktreeCode != "." {
            status.unstaged.append(GitChange(
                path: path, status: GitFileStatus(code: worktreeCode),
                isUntracked: false, originalPath: originalPath))
        }
    }

    /// Parses the US/RS-joined `git log` format used by `log(limit:)`.
    static func parseLog(_ raw: String) -> [GitCommit] {
        let formatter = ISO8601DateFormatter()
        return raw.components(separatedBy: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\u{1f}")
            guard fields.count == 6, !fields[0].isEmpty else { return nil }
            return GitCommit(
                sha: fields[0],
                shortSHA: fields[1],
                subject: fields[2],
                author: fields[3],
                authorEmail: fields[4],
                date: formatter.date(from: fields[5]) ?? Date(timeIntervalSince1970: 0)
            )
        }
    }
}
