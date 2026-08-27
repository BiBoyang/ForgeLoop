// Ported from termio (MIT): https://github.com/termio-sh/termio
// Original: Sources/termio/Git/WorktreeService.swift
// Copyright (c) 2026 Jiwei Yuan
// https://github.com/termio-sh/termio/blob/main/LICENSE
import Foundation

/// One linked git worktree, as reported by `git worktree list --porcelain`.
public struct Worktree: Hashable, Sendable, Identifiable {
    /// Standardized absolute path of the checkout.
    public let path: String
    /// The commit the worktree has checked out.
    public let head: String
    /// Short branch name, `nil` on a detached HEAD.
    public let branch: String?
    /// The repository's primary checkout (the first record git emits).
    public let isPrimary: Bool

    public init(path: String, head: String, branch: String?, isPrimary: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isPrimary = isPrimary
    }

    public var id: String { path }
}

/// Discovers and manages a repository's linked worktrees. Stateless: git's own
/// output is the source of truth, so nothing is cached between calls.
public struct WorktreeService: Sendable {
    public let repository: URL

    public init(repository: URL) {
        self.repository = repository
    }

    /// All worktrees of the repository, primary checkout first, in git's order.
    /// Bare and prunable entries are skipped, as is any path that no longer
    /// exists on disk — a stale worktree listed there would hand callers a
    /// missing working directory.
    public func list() async throws -> [Worktree] {
        try await GitRunner.offThread {
            try GitRunner.validateRepository(repository)
            let output = try GitRunner.run(["worktree", "list", "--porcelain"], in: repository)
            return Self.parseWorktreeList(output.stdout)
        }
    }

    /// Creates a worktree at `path`. With `branch` set, a new branch of that name
    /// is created at HEAD for the worktree; without one, git derives the branch
    /// name from the path's last component.
    public func add(at path: URL, branch: String? = nil) async throws {
        try await GitRunner.offThread {
            try GitRunner.validateRepository(repository)
            var arguments = ["worktree", "add"]
            if let branch { arguments += ["-b", branch] }
            arguments.append(path.path)
            try GitRunner.run(arguments, in: repository)
        }
    }

    /// Removes the worktree at `path`. git refuses a dirty worktree unless
    /// `force` is set; the failure surfaces as `GitError.commandFailed` with
    /// git's own stderr.
    public func remove(at path: URL, force: Bool = false) async throws {
        try await GitRunner.offThread {
            try GitRunner.validateRepository(repository)
            var arguments = ["worktree", "remove"]
            if force { arguments.append("--force") }
            arguments.append(path.path)
            try GitRunner.run(arguments, in: repository)
        }
    }

    /// Turns a proposed worktree/branch name into a filesystem-safe folder name:
    /// path separators and whitespace collapse to hyphens (`my feature/x` →
    /// `my-feature-x`); empty input becomes "worktree".
    public static func sanitizedName(_ proposed: String) -> String {
        let base = proposed
            .components(separatedBy: CharacterSet(charactersIn: "/\\").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return base.isEmpty ? "worktree" : base
    }

    // MARK: - Parsing

    /// Parses `git worktree list --porcelain`: blank-line-separated records, each
    /// opening with `worktree <path>`. The first record is the primary checkout.
    static func parseWorktreeList(_ text: String) -> [Worktree] {
        var result: [Worktree] = []
        for (index, record) in text.components(separatedBy: "\n\n").enumerated() {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let worktreeLine = lines.first(where: { $0.hasPrefix("worktree ") }) else { continue }
            if lines.contains(where: { $0 == "bare" }) { continue }
            if lines.contains(where: { $0.hasPrefix("prunable") }) { continue }
            let path = String(worktreeLine.dropFirst("worktree ".count))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let head = lines.first(where: { $0.hasPrefix("HEAD ") })
                .map { String($0.dropFirst("HEAD ".count)) } ?? ""
            let branch = lines.first(where: { $0.hasPrefix("branch ") })
                .map { String($0.dropFirst("branch ".count).replacingOccurrences(of: "refs/heads/", with: "")) }
            result.append(Worktree(
                path: URL(fileURLWithPath: path).standardizedFileURL.path,
                head: head,
                branch: branch,
                isPrimary: index == 0
            ))
        }
        return result
    }
}
