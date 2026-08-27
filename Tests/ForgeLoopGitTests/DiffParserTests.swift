import XCTest
@testable import ForgeLoopGit

final class DiffParserTests: XCTestCase {
    func testParsesHunkLineNumbersAndKinds() {
        let text = """
        diff --git a/file.txt b/file.txt
        index 257cc56..5716ca5 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -1,3 +1,4 @@ func contextHeading()
         one
        -two
        +TWO
        +two point five
         three
        """
        let files = DiffParser.parse(text)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.oldPath, "file.txt")
        XCTAssertEqual(files.first?.newPath, "file.txt")
        XCTAssertEqual(files.first?.path, "file.txt")

        let hunk = files.first?.hunks.first
        XCTAssertEqual(hunk?.oldStart, 1)
        XCTAssertEqual(hunk?.oldCount, 3)
        XCTAssertEqual(hunk?.newStart, 1)
        XCTAssertEqual(hunk?.newCount, 4)
        XCTAssertEqual(hunk?.heading, "func contextHeading()")

        let lines = hunk?.lines ?? []
        XCTAssertEqual(lines.map(\.kind),
                       [.context, .deletion, .addition, .addition, .context])
        XCTAssertEqual(lines[0].oldLine, 1)
        XCTAssertEqual(lines[0].newLine, 1)
        XCTAssertEqual(lines[1].oldLine, 2)
        XCTAssertNil(lines[1].newLine)
        XCTAssertEqual(lines[2].newLine, 2)
        XCTAssertNil(lines[2].oldLine)
        XCTAssertEqual(lines[4].oldLine, 3)
        XCTAssertEqual(lines[4].newLine, 4)
        // `text` carries no `+`/`-`/space marker.
        XCTAssertEqual(lines[1].text, "two")
        XCTAssertEqual(lines[2].text, "TWO")
    }

    func testParsesMultipleFilesWithNewAndDeletedPaths() {
        let text = """
        diff --git a/added.txt b/added.txt
        new file mode 100644
        index 0000000..3b18e51
        --- /dev/null
        +++ b/added.txt
        @@ -0,0 +1 @@
        +hello
        diff --git a/deleted.txt b/deleted.txt
        deleted file mode 100644
        index 3b18e51..0000000
        --- a/deleted.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -goodbye
        """
        let files = DiffParser.parse(text)

        XCTAssertEqual(files.count, 2)
        XCTAssertNil(files[0].oldPath)
        XCTAssertEqual(files[0].newPath, "added.txt")
        XCTAssertEqual(files[0].hunks.first?.lines.first?.kind, .addition)
        XCTAssertEqual(files[1].oldPath, "deleted.txt")
        XCTAssertNil(files[1].newPath)
        XCTAssertEqual(files[1].path, "deleted.txt")
        XCTAssertEqual(files[1].hunks.first?.lines.first?.kind, .deletion)
    }

    func testIgnoresNoNewlineMarker() {
        let text = """
        diff --git a/f.txt b/f.txt
        index 3b18e51..1f9c6e0 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let files = DiffParser.parse(text)
        let lines = files.first?.hunks.first?.lines ?? []
        XCTAssertEqual(lines.map(\.kind), [.deletion, .addition])
    }

    func testIntralineEmphasisPairsDeletionWithAddition() {
        let text = """
        diff --git a/f.swift b/f.swift
        index 3b18e51..1f9c6e0 100644
        --- a/f.swift
        +++ b/f.swift
        @@ -1 +1 @@
        -let total = compute(base, 1)
        +let total = compute(base, 2)
        """
        let files = DiffParser.parse(text)
        let lines = files.first?.hunks.first?.lines ?? []
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[0].emphasis.isEmpty)
        XCTAssertFalse(lines[1].emphasis.isEmpty)
        // Only the changed literal is emphasized; the shared prefix is not.
        XCTAssertEqual(lines[0].emphasis.first?.lowerBound, "let total = compute(base, ".count)
    }

    func testIntralineEmphasisSkippedForRewrittenLines() {
        let text = """
        diff --git a/f.txt b/f.txt
        index 3b18e51..1f9c6e0 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1 +1 @@
        -aaaaaaaaaaaaaaaaaaaa
        +ZZZZZZZZZZZZZZZZZZZZ
        """
        let files = DiffParser.parse(text)
        let lines = files.first?.hunks.first?.lines ?? []
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].emphasis.isEmpty)
        XCTAssertTrue(lines[1].emphasis.isEmpty)
    }

    func testRealDiffRoundTripsThroughParser() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\ntwo\nthree\n")
        try fixture.commit("initial")
        try fixture.write("a.txt", "one\nTWO\nthree\n")

        let text = try await GitService(repository: fixture.root).diff(path: "a.txt")
        let files = DiffParser.parse(text)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.path, "a.txt")
        let lines = files.first?.hunks.first?.lines ?? []
        XCTAssertTrue(lines.contains(where: { $0.kind == .deletion && $0.text == "two" }))
        XCTAssertTrue(lines.contains(where: { $0.kind == .addition && $0.text == "TWO" }))
    }
}
