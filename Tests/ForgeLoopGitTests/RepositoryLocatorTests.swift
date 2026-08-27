import XCTest
@testable import ForgeLoopGit

final class RepositoryLocatorTests: XCTestCase {
    private var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeLoopGitTests-locator-\(UUID().uuidString)")
    }

    func testFindsRootFromNestedDirectory() throws {
        let root = temporaryDirectory
        let nested = root.appendingPathComponent("a")
            .appendingPathComponent("b")
            .appendingPathComponent("c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(GitRepositoryLocator.findRoot(containing: nested), root.standardizedFileURL)
    }

    func testFindsDirectoryItself() throws {
        let root = temporaryDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A `.git` *file* (linked worktree / submodule style) counts as a marker.
        try "gitdir: ../elsewhere".write(
            to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(GitRepositoryLocator.findRoot(containing: root), root.standardizedFileURL)
    }

    func testReturnsNilOutsideAnyRepository() throws {
        let root = temporaryDirectory
        let nested = root.appendingPathComponent("a").appendingPathComponent("b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Holds as long as the machine's temp directory sits outside a checkout.
        XCTAssertNil(GitRepositoryLocator.findRoot(containing: nested))
    }
}
