import XCTest
@testable import ForgeLoopGit

final class GitServiceTests: XCTestCase {
    func testStatusIsEmptyOnCleanRepository() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\n")
        try fixture.commit("initial")

        let status = try await GitService(repository: fixture.root).status()
        XCTAssertTrue(status.isEmpty)
    }

    func testStatusSplitsStagedUnstagedAndUntracked() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\n")
        try fixture.commit("initial")

        try fixture.write("a.txt", "one\ntwo\n")   // unstaged modification
        try fixture.write("b.txt", "new\n")
        _ = try fixture.git(["add", "b.txt"])       // staged addition
        try fixture.write("c.txt", "loose\n")       // untracked

        let status = try await GitService(repository: fixture.root).status()

        XCTAssertEqual(status.staged.map(\.path), ["b.txt"])
        XCTAssertEqual(status.staged.first?.status, .added)
        XCTAssertEqual(status.unstaged.map(\.path), ["a.txt"])
        XCTAssertEqual(status.unstaged.first?.status, .modified)
        XCTAssertEqual(status.untracked.map(\.path), ["c.txt"])
        XCTAssertEqual(status.untracked.first?.status, .untracked)
    }

    func testStatusReportsStagedRenameWithOriginalPath() async throws {
        let fixture = try GitFixture()
        try fixture.write("before.txt", "one\ntwo\nthree\n")
        try fixture.commit("initial")
        _ = try fixture.git(["mv", "before.txt", "after.txt"])

        let status = try await GitService(repository: fixture.root).status()

        XCTAssertEqual(status.staged.count, 1)
        let rename = status.staged.first
        XCTAssertEqual(rename?.status, .renamed)
        XCTAssertEqual(rename?.path, "after.txt")
        XCTAssertEqual(rename?.originalPath, "before.txt")
    }

    func testLogReturnsCommitsNewestFirst() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\n")
        try fixture.commit("first subject")
        try fixture.write("a.txt", "one\ntwo\n")
        try fixture.commit("second subject")

        let commits = try await GitService(repository: fixture.root).log()

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits.first?.subject, "second subject")
        XCTAssertEqual(commits.last?.subject, "first subject")
        XCTAssertEqual(commits.first?.author, "Fixture")
        XCTAssertEqual(commits.first?.authorEmail, "fixture@example.com")
        XCTAssertEqual(commits.first?.sha.count, 40)
        if let date = commits.first?.date {
            XCTAssertLessThan(abs(date.timeIntervalSinceNow), 3600)
        }
    }

    func testLogIsEmptyOnRepositoryWithoutCommits() async throws {
        let fixture = try GitFixture()
        let commits = try await GitService(repository: fixture.root).log()
        XCTAssertEqual(commits, [])
    }

    func testCurrentBranchMatchesGit() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\n")
        try fixture.commit("initial")

        // Compare against git's own answer so the test is independent of the
        // machine's configured default branch name.
        let expected = try fixture.git(["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = try await GitService(repository: fixture.root).currentBranch()
        XCTAssertEqual(branch, expected)
    }

    func testDiffWorkingTreeAndStaged() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\ntwo\nthree\n")
        try fixture.commit("initial")
        try fixture.write("a.txt", "one\nTWO\nthree\n")

        let service = GitService(repository: fixture.root)
        let workingTree = try await service.diff(path: "a.txt")
        XCTAssertTrue(workingTree.contains("-two"))
        XCTAssertTrue(workingTree.contains("+TWO"))
        let nothingStaged = try await service.diff(path: "a.txt", staged: true)
        XCTAssertFalse(nothingStaged.contains("+TWO"))

        _ = try fixture.git(["add", "a.txt"])
        let staged = try await service.diff(path: "a.txt", staged: true)
        XCTAssertTrue(staged.contains("+TWO"))
    }

    func testCommitDiffShowsOnlyThatCommit() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\n")
        try fixture.commit("first")
        try fixture.write("a.txt", "one\ntwo\n")
        try fixture.commit("second")

        let service = GitService(repository: fixture.root)
        let commits = try await service.log()
        guard commits.count == 2 else { return XCTFail("expected 2 commits") }

        let secondDiff = try await service.commitDiff(commits[0].sha)
        XCTAssertTrue(secondDiff.contains("+two"))
        XCTAssertFalse(secondDiff.contains("commit "), "--format= strips the commit header")
    }

    func testStatusThrowsForMissingPath() async throws {
        try GitFixture.requireGit()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeLoopGitTests-missing-\(UUID().uuidString)")
        do {
            _ = try await GitService(repository: missing).status()
            XCTFail("expected repositoryNotFound")
        } catch let error as GitError {
            guard case .repositoryNotFound(let path) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, missing.path)
        }
    }

    func testStatusThrowsForNonRepositoryDirectory() async throws {
        try GitFixture.requireGit()
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeLoopGitTests-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }

        do {
            _ = try await GitService(repository: plain).status()
            XCTFail("expected notARepository")
        } catch let error as GitError {
            guard case .notARepository(let path) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, plain.path)
        }
    }

    func testParseStatusHandlesHandwrittenRecords() {
        // One ordinary record ("1 .M ..."), one rename ("2 R100 ..." + origPath
        // token), one untracked, one ignored entry.
        let raw = "1 .M N... 100644 100644 100644 abc def mod.txt\0"
            + "2 R. N... 100644 100644 100644 abc def R100 new.txt\0old.txt\0"
            + "? loose.txt\0"
            + "! ignored.txt\0"
        let status = GitService.parseStatus(raw)

        XCTAssertEqual(status.unstaged.map(\.path), ["mod.txt"])
        XCTAssertEqual(status.staged.count, 1)
        XCTAssertEqual(status.staged.first?.status, .renamed)
        XCTAssertEqual(status.staged.first?.originalPath, "old.txt")
        XCTAssertEqual(status.untracked.map(\.path), ["loose.txt"])
    }

    func testParseLogHandlesHandwrittenRecords() {
        let raw = ["aabbccdd00112233445566778899aabbccddee", "aabbccd", "subject with spaces",
                   "Author Name", "author@example.com", "2026-08-27T16:19:09+08:00"]
            .joined(separator: "\u{1f}") + "\u{1e}"
        let commits = GitService.parseLog(raw)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.subject, "subject with spaces")
        XCTAssertEqual(commits.first?.shortSHA, "aabbccd")
        XCTAssertNotEqual(commits.first?.date, Date(timeIntervalSince1970: 0))
    }
}
