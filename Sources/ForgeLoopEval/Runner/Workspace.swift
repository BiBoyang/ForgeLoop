import Foundation

/// An isolated temporary workspace for a single eval case.
///
/// `Workspace` creates a unique directory under `FileManager.default.temporaryDirectory`,
/// writes the eval's initial files into it, and cleans it up when no longer needed.
///
/// All path operations are performed relative to the workspace root, and the actor
/// isolation guarantees that concurrent writes to the same workspace are serialized.
public actor Workspace {
    /// The root directory of this workspace.
    public nonisolated let rootURL: URL

    private let shouldCleanup: Bool

    /// Create a workspace at an explicit root URL.
    ///
    /// - Parameters:
    ///   - rootURL: The directory to use as the workspace root. It must be a
    ///     `temporaryDirectory` subdirectory.
    ///   - shouldCleanup: Whether `cleanup()` removes the directory. Defaults to `true`.
    public init(
        rootURL: URL,
        shouldCleanup: Bool = true
    ) throws {
        let tempDir = FileManager.default.temporaryDirectory.standardizedFileURL
        let standardizedRoot = rootURL.standardizedFileURL
        guard standardizedRoot.path.hasPrefix(tempDir.path) else {
            throw WorkspaceError.notUnderTemporaryDirectory(rootURL: rootURL)
        }
        self.rootURL = standardizedRoot
        self.shouldCleanup = shouldCleanup
    }

    /// Create a new temporary workspace with a unique directory name.
    ///
    /// - Parameters:
    ///   - prefix: A prefix for the directory name. Defaults to "ForgeLoopEval".
    ///   - shouldCleanup: Whether `cleanup()` removes the directory. Defaults to `true`.
    /// - Returns: A workspace whose `rootURL` is a fresh subdirectory of the
    ///   system temporary directory.
    public static func makeTemporary(
        prefix: String = "ForgeLoopEval",
        shouldCleanup: Bool = true
    ) async throws -> Workspace {
        let tempDir = FileManager.default.temporaryDirectory
        let name = "\(prefix)-\(UUID().uuidString)"
        let rootURL = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return try Workspace(
            rootURL: rootURL,
            shouldCleanup: shouldCleanup
        )
    }

    /// Write a single initial file into the workspace.
    ///
    /// Relative paths are resolved against `rootURL`. Paths that escape the
    /// workspace (e.g. containing `..`) are rejected.
    public func write(_ file: EvalFile) throws {
        let targetURL = try resolvedURL(for: file.path)
        let parentDir = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try file.content.write(to: targetURL, atomically: true, encoding: .utf8)
    }

    /// Write multiple initial files into the workspace.
    public func write(files: [EvalFile]) throws {
        for file in files {
            try write(file)
        }
    }

    /// Remove the workspace directory and all of its contents.
    ///
    /// This is a no-op when `shouldCleanup` is `false`.
    public func cleanup() throws {
        guard shouldCleanup else { return }
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        try FileManager.default.removeItem(at: rootURL)
    }

    /// Resolve a relative path against the workspace root, rejecting escapes.
    ///
    /// The returned URL is standardized and guaranteed to reside under
    /// `rootURL`. Paths containing `..` as a path component, or paths that
    /// resolve outside the workspace (e.g. via symlinks), are rejected.
    public func resolvedURL(for path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            throw WorkspaceError.invalidPath(path: path, reason: "path is empty")
        }
        let components = trimmed.split(separator: "/")
        guard !components.contains("..") else {
            throw WorkspaceError.invalidPath(path: path, reason: "path escapes workspace")
        }
        let target = rootURL.appendingPathComponent(trimmed, isDirectory: false)
        let standardizedRoot = rootURL.standardizedFileURL
        let standardizedTarget = target.standardizedFileURL
        guard standardizedTarget.path.hasPrefix(standardizedRoot.path) else {
            throw WorkspaceError.invalidPath(path: path, reason: "path escapes workspace")
        }
        return standardizedTarget
    }
}

public enum WorkspaceError: Error, LocalizedError {
    case notUnderTemporaryDirectory(rootURL: URL)
    case invalidPath(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notUnderTemporaryDirectory(let rootURL):
            return "Workspace root \(rootURL) is not under the system temporary directory"
        case .invalidPath(let path, let reason):
            return "Invalid path '\(path)': \(reason)"
        }
    }
}
