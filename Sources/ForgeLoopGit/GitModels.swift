// Inspired by termio (MIT): https://github.com/termio-sh/termio
import Foundation

/// The change kind of one file, derived from a porcelain status code.
public enum GitFileStatus: String, Sendable, Equatable {
    case modified, added, deleted, renamed, copied, untracked, conflicted

    /// Maps a porcelain status letter (`M`, `A`, `R`, …) onto a change kind.
    public init(code: Character) {
        switch code {
        case "M", "T": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "U": self = .conflicted
        case "?": self = .untracked
        default: self = .modified
        }
    }
}

/// One changed file, as reported by `git status`. `path` is POSIX-style, relative
/// to the repository root.
public struct GitChange: Hashable, Sendable {
    public let path: String
    public let status: GitFileStatus
    public let isUntracked: Bool
    /// For a rename or copy, the path the file moved from.
    public var originalPath: String?

    public init(path: String, status: GitFileStatus, isUntracked: Bool, originalPath: String? = nil) {
        self.path = path
        self.status = status
        self.isUntracked = isUntracked
        self.originalPath = originalPath
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// A snapshot of the working tree, split by where each change sits.
public struct GitStatus: Sendable, Equatable {
    /// Changes in the index — what `git commit` would take right now.
    public var staged: [GitChange]
    /// Tracked changes in the working tree not yet staged.
    public var unstaged: [GitChange]
    /// Files git has never seen.
    public var untracked: [GitChange]

    public init(staged: [GitChange] = [], unstaged: [GitChange] = [], untracked: [GitChange] = []) {
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
    }

    public var isEmpty: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty }
}

/// One commit in the branch's history, parsed from `git log`.
public struct GitCommit: Hashable, Sendable, Identifiable {
    /// Full 40-char SHA.
    public let sha: String
    /// Abbreviated SHA for display.
    public let shortSHA: String
    public let subject: String
    public let author: String
    public let authorEmail: String
    /// Author date.
    public let date: Date

    public init(sha: String, shortSHA: String, subject: String,
                author: String, authorEmail: String, date: Date) {
        self.sha = sha
        self.shortSHA = shortSHA
        self.subject = subject
        self.author = author
        self.authorEmail = authorEmail
        self.date = date
    }

    public var id: String { sha }
}
