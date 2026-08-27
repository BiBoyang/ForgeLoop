import XCTest

/// A real git repository in a temporary directory, used to exercise parsing
/// against git's own output rather than hand-recorded fixtures.
final class GitFixture {
    enum FixtureError: Error {
        case gitFailed(String)
    }

    let root: URL

    init() throws {
        try GitFixture.requireGit()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeLoopGitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try git(["init"])
        _ = try git(["config", "user.name", "Fixture"])
        _ = try git(["config", "user.email", "fixture@example.com"])
        _ = try git(["config", "commit.gpgsign", "false"])
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Skips the calling test when no git executable is available.
    static func requireGit() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("/usr/bin/git is not available on this machine")
        }
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw FixtureError.gitFailed(output)
        }
        return output
    }

    func write(_ name: String, _ contents: String) throws {
        try contents.write(to: root.appendingPathComponent(name),
                           atomically: true, encoding: .utf8)
    }

    func remove(_ name: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(name))
    }

    func commit(_ message: String) throws {
        _ = try git(["add", "-A"])
        _ = try git(["commit", "-m", message])
    }
}
