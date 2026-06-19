import XCTest
@testable import ForgeLoopDiagnostics

final class SensitiveDataMaskerTests: XCTestCase {
    private var masker: SensitiveDataMasker {
        get async { SensitiveDataMasker() }
    }

    func testMasksAPIKey() async {
        let masked = await masker.mask("key: sk-abc123xyz45678901234567890")
        XCTAssertEqual(masked, "key: ***")
    }

    func testMasksBearerToken() async {
        let masked = await masker.mask("Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
        XCTAssertEqual(masked, "Authorization: Bearer ***")
    }

    func testMasksStandaloneBearerToken() async {
        let masked = await masker.mask("Bearer secret-token-value-123")
        XCTAssertEqual(masked, "Bearer ***")
    }

    func testReplacesHomeDirectory() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let masked = await masker.mask("path: \(home)/Documents/file.txt")
        XCTAssertEqual(masked, "path: ~/Documents/file.txt")
    }

    func testMaskedAttributePassthrough() async {
        let attributes: [String: TraceAttribute] = [
            "secret": .masked("keep-me"),
            "plain": .string("replace sk-abc123xyz45678901234567890")
        ]
        let masked = await masker.maskAttributes(attributes)
        XCTAssertEqual(masked["secret"], .masked("keep-me"))
        XCTAssertEqual(masked["plain"], .string("replace ***"))
    }

    func testPreservePrefixLength() async {
        let masked = await masker.mask("this is a long message content", preservePrefixLength: 10)
        XCTAssertEqual(masked, "this is a ***")
    }
}
