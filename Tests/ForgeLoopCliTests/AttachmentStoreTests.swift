import XCTest
@testable import ForgeLoopCli

@MainActor
final class AttachmentStoreTests: XCTestCase {

    // MARK: - Add

    func testAddTextReturnsRecordWithTextKind() {
        let store = AttachmentStore()
        let record = store.addText("hello world")

        XCTAssertEqual(record.kind, .text("hello world"))
        XCTAssertFalse(record.id.value.isEmpty)
    }

    func testAddFilePathReturnsRecordWithPathKind() {
        let store = AttachmentStore()
        let record = store.addFilePath("/tmp/test.swift")

        XCTAssertEqual(record.kind, .filePath("/tmp/test.swift"))
    }

    func testAddMultipleAttachments() {
        let store = AttachmentStore()
        store.addText("first")
        store.addText("second")
        store.addFilePath("/a/b")

        XCTAssertEqual(store.count, 3)
    }

    // MARK: - List

    func testListReturnsAllRecordsInOrder() {
        let store = AttachmentStore()
        let r1 = store.addText("one")
        let r2 = store.addText("two")
        let r3 = store.addFilePath("/path")

        let list = store.list()

        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0], r1)
        XCTAssertEqual(list[1], r2)
        XCTAssertEqual(list[2], r3)
    }

    func testListReturnsSnapshotDoesNotAffectStore() {
        let store = AttachmentStore()
        store.addText("x")

        var list = store.list()
        list.removeAll()

        XCTAssertEqual(store.count, 1)
    }

    // MARK: - Remove by id

    func testRemoveByIdRemovesMatchingRecord() {
        let store = AttachmentStore()
        let r1 = store.addText("one")
        let r2 = store.addText("two")

        let removed = store.remove(id: r1.id)

        XCTAssertTrue(removed)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.list()[0], r2)
    }

    func testRemoveByIdReturnsFalseForUnknownId() {
        let store = AttachmentStore()
        store.addText("one")

        let removed = store.remove(id: AttachmentID())

        XCTAssertFalse(removed)
        XCTAssertEqual(store.count, 1)
    }

    // MARK: - Remove at index

    func testRemoveAtIndexRemovesCorrectRecord() {
        let store = AttachmentStore()
        store.addText("one")
        store.addText("two")
        store.addText("three")

        let removed = store.remove(at: 1)

        XCTAssertTrue(removed)
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.list()[0].kind, .text("one"))
        XCTAssertEqual(store.list()[1].kind, .text("three"))
    }

    func testRemoveAtIndexReturnsFalseForOutOfBounds() {
        let store = AttachmentStore()
        store.addText("one")

        XCTAssertFalse(store.remove(at: -1))
        XCTAssertFalse(store.remove(at: 5))
        XCTAssertEqual(store.count, 1)
    }

    // MARK: - Clear

    func testClearRemovesAllRecords() {
        let store = AttachmentStore()
        store.addText("one")
        store.addFilePath("/tmp")

        store.clear()

        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.count, 0)
    }

    // MARK: - Snapshot

    func testSnapshotIsStableAndOrdered() {
        let store = AttachmentStore()
        let r1 = store.addText("alpha")
        let r2 = store.addFilePath("/beta")

        let snapshot1 = store.snapshot()
        let snapshot2 = store.snapshot()

        XCTAssertEqual(snapshot1, snapshot2)
        XCTAssertEqual(snapshot1[0], r1)
        XCTAssertEqual(snapshot1[1], r2)
    }

    // MARK: - Display preview

    func testTextPreviewTruncatesLongContent() {
        let longText = String(repeating: "a", count: 100)
        let record = AttachmentRecord(kind: .text(longText))

        let preview = record.displayPreview

        XCTAssertTrue(preview.hasSuffix("..."))
        XCTAssertTrue(preview.hasPrefix("[text]"))
    }

    func testPathPreviewShowsFullPath() {
        let record = AttachmentRecord(kind: .filePath("/usr/local/bin/tool"))

        XCTAssertEqual(record.displayPreview, "[file] /usr/local/bin/tool")
    }

    func testTextPreviewNormalizesNewlinesToSpaces() {
        let record = AttachmentRecord(kind: .text("line one\nline two\rline three\r\nline four"))

        let preview = record.displayPreview

        XCTAssertEqual(preview, "[text] line one line two line three line four")
    }

    func testTextPreviewCollapsesMultipleNewlines() {
        let record = AttachmentRecord(kind: .text("a\n\n\nb"))

        let preview = record.displayPreview

        XCTAssertEqual(preview, "[text] a   b")
    }

    // MARK: - injectAttachments

    func testInjectAttachmentsWithEmptyListReturnsOriginalText() {
        let result = injectAttachments(into: "hello", attachments: [])
        XCTAssertEqual(result, "hello")
    }

    func testInjectAttachmentsPrefixesTextAttachments() {
        let attachments = [
            AttachmentRecord(kind: .text("content A")),
            AttachmentRecord(kind: .text("content B")),
        ]
        let result = injectAttachments(into: "prompt", attachments: attachments)

        XCTAssertTrue(result.hasPrefix("content A\n\ncontent B"))
        XCTAssertTrue(result.hasSuffix("prompt"))
    }

    func testInjectAttachmentsPrefixesPathAttachments() {
        let attachments = [
            AttachmentRecord(kind: .filePath("/tmp/main.swift")),
        ]
        let result = injectAttachments(into: "review this file", attachments: attachments)

        XCTAssertTrue(result.hasPrefix("[Attached file: /tmp/main.swift]"))
        XCTAssertTrue(result.hasSuffix("review this file"))
    }

    func testInjectAttachmentsMixedKinds() {
        let attachments = [
            AttachmentRecord(kind: .text("some text")),
            AttachmentRecord(kind: .filePath("/tmp/file.swift")),
        ]
        let result = injectAttachments(into: "prompt", attachments: attachments)

        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(lines.contains("some text"))
        XCTAssertTrue(lines.contains("[Attached file: /tmp/file.swift]"))
        XCTAssertTrue(lines.contains("prompt"))
    }
}
