import XCTest
@testable import ForgeLoopDiagnostics

final class FileLogSinkTests: XCTestCase {
    private var temporaryFileURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("test.log")
    }

    func testWritesToFile() async throws {
        let fileURL = temporaryFileURL
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let sink = FileLogSink(fileURL: fileURL)
        await sink.log(level: .info, message: "first", attributes: [:])

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("\"message\":\"first\""))
        XCTAssertTrue(content.contains("\"level\":\"info\""))
    }

    func testRotatesWhenSizeLimitReached() async throws {
        let fileURL = temporaryFileURL
        let directory = fileURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sink = FileLogSink(fileURL: fileURL, maxFileSize: 64, maxFiles: 2)

        await sink.log(level: .info, message: "one", attributes: [:])
        await sink.log(level: .info, message: "two", attributes: [:])
        await sink.log(level: .info, message: "three", attributes: [:])

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let logFiles = files.filter { $0.hasPrefix("test") }
        XCTAssertGreaterThanOrEqual(logFiles.count, 2)
        XCTAssertTrue(logFiles.contains("test.log"))
        XCTAssertTrue(logFiles.contains("test.log.1"))
    }
}
