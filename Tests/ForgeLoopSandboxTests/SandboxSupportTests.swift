import XCTest
@testable import ForgeLoopSandbox

final class SandboxSupportTests: XCTestCase {

    func testEnsureSupportedWhenExecutableExists() {
        XCTAssertNoThrow(try SandboxSupport.ensureSupported(executableCheck: { _ in true }))
    }

    func testEnsureSupportedThrowsWhenMissing() {
        XCTAssertThrowsError(try SandboxSupport.ensureSupported(executableCheck: { _ in false })) { error in
            XCTAssertEqual(error as? SandboxSupport.SupportError,
                           .sandboxExecMissing(path: "/usr/bin/sandbox-exec"))
        }
    }

    #if os(macOS)
    func testRealSandboxExecExistsOnMacOS() {
        XCTAssertTrue(SandboxSupport.isSupported)
        XCTAssertNoThrow(try SandboxSupport.ensureSupported())
    }
    #endif
}
