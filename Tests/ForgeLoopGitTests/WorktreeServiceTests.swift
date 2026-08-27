import XCTest
@testable import ForgeLoopGit

final class WorktreeServiceTests: XCTestCase {
    func testListContainsOnlyPrimaryInitially() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\n")
        try fixture.commit("initial")

        let worktrees = try await WorktreeService(repository: fixture.root).list()

        XCTAssertEqual(worktrees.count, 1)
        XCTAssertEqual(worktrees.first?.isPrimary, true)
        XCTAssertEqual(worktrees.first?.path, fixture.root.standardized.path)
        XCTAssertEqual(worktrees.first?.head.count, 40)
        XCTAssertNotNil(worktrees.first?.branch)
    }

    func testAddAndRemoveWorktree() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\n")
        try fixture.commit("initial")

        let service = WorktreeService(repository: fixture.root)
        let worktreePath = fixture.root.appendingPathComponent("linked")

        try await service.add(at: worktreePath, branch: "linked-branch")
        var worktrees = try await service.list()
        XCTAssertEqual(worktrees.count, 2)
        let linked = worktrees.first(where: { !$0.isPrimary })
        XCTAssertEqual(linked?.branch, "linked-branch")
        XCTAssertEqual(linked?.path, worktreePath.standardized.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath.path))

        try await service.remove(at: worktreePath)
        worktrees = try await service.list()
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath.path))
    }

    func testListSkipsWorktreeWhoseDirectoryVanished() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\n")
        try fixture.commit("initial")

        let service = WorktreeService(repository: fixture.root)
        let worktreePath = fixture.root.appendingPathComponent("linked")
        try await service.add(at: worktreePath, branch: "linked-branch")

        // Delete the checkout out from under git: the entry turns prunable and
        // must not be handed to callers as a usable worktree.
        try FileManager.default.removeItem(at: worktreePath)
        let worktrees = try await service.list()
        XCTAssertEqual(worktrees.count, 1)

        // Re-add so the fixture's cleanup finds a consistent tree.
        _ = try? fixture.git(["worktree", "prune"])
    }

    func testRemoveDirtyWorktreeFailsWithStderr() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\n")
        try fixture.commit("initial")

        let service = WorktreeService(repository: fixture.root)
        let worktreePath = fixture.root.appendingPathComponent("linked")
        try await service.add(at: worktreePath, branch: "linked-branch")
        try "dirty\n".write(to: worktreePath.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)

        do {
            try await service.remove(at: worktreePath)
            XCTFail("expected commandFailed")
        } catch let error as GitError {
            guard case .commandFailed(_, _, let stderr) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertFalse(stderr.isEmpty)
        }

        _ = try? fixture.git(["worktree", "remove", "--force", worktreePath.path])
    }

    func testForceRemoveDropsDirtyWorktree() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\n")
        try fixture.commit("initial")

        let service = WorktreeService(repository: fixture.root)
        let worktreePath = fixture.root.appendingPathComponent("linked")
        try await service.add(at: worktreePath, branch: "linked-branch")
        try "dirty\n".write(to: worktreePath.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)

        try await service.remove(at: worktreePath, force: true)
        let worktrees = try await service.list()
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath.path))
    }

    func testSanitizedName() {
        XCTAssertEqual(WorktreeService.sanitizedName("my feature/x"), "my-feature-x")
        XCTAssertEqual(WorktreeService.sanitizedName("  spaces  "), "spaces")
        XCTAssertEqual(WorktreeService.sanitizedName("plain"), "plain")
        XCTAssertEqual(WorktreeService.sanitizedName("  \n"), "worktree")
    }
}
