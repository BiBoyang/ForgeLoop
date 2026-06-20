import XCTest
@testable import ForgeLoopDiagnostics

final class SensitiveDataMaskerTests: XCTestCase {
    private let masker = SensitiveDataMasker()

    func testMasksAPIKey() {
        let masked = masker.mask("key: sk-abc123xyz45678901234567890")
        XCTAssertEqual(masked, "key: ***")
    }

    func testMasksBearerToken() {
        let masked = masker.mask("Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
        XCTAssertEqual(masked, "Authorization: Bearer ***")
    }

    func testMasksStandaloneBearerToken() {
        let masked = masker.mask("Bearer secret-token-value-123")
        XCTAssertEqual(masked, "Bearer ***")
    }

    func testReplacesHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let masked = masker.mask("path: \(home)/Documents/file.txt")
        XCTAssertEqual(masked, "path: ~/Documents/file.txt")
    }

    func testMaskedAttributePassthrough() {
        let attributes: [String: TraceAttribute] = [
            "secret": .masked("keep-me"),
            "plain": .string("replace sk-abc123xyz45678901234567890")
        ]
        let masked = masker.maskAttributes(attributes)
        XCTAssertEqual(masked["secret"], .masked("keep-me"))
        XCTAssertEqual(masked["plain"], .string("replace ***"))
    }

    func testPreservePrefixLength() {
        let masked = masker.mask("this is a long message content", preservePrefixLength: 10)
        XCTAssertEqual(masked, "this is a ***")
    }
}
