import Foundation

/// Finds the repository root containing a directory by walking up toward the
/// filesystem root looking for a `.git` entry. A `.git` *file* counts too —
/// linked worktrees and submodules use one to point at their real git dir.
public enum GitRepositoryLocator {
    /// The nearest ancestor of `url` (itself included) that carries a `.git`
    /// entry, or `nil` when the directory is not inside any repository.
    public static func findRoot(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        while true {
            let marker = current.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: marker.path) { return current }
            // Stop on the path-component count rather than on a parent == current
            // fixpoint: for degenerate paths (`/..`-style), deletingLastPathComponent
            // keeps producing a *different* string forever instead of settling.
            if current.pathComponents.count <= 1 { return nil }
            current = current.deletingLastPathComponent()
        }
    }
}
