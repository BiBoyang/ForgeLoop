import XCTest
@testable import ForgeLoopSandbox

/// 输入输出断言风格对齐 Codex `manager_tests.rs`：profile + command → 断言 argv。
final class SandboxTransformTests: XCTestCase {

    func testFullAccessWithNetworkPassesThroughUnchanged() {
        let argv = SandboxTransform.wrap(
            command: "/bin/echo",
            arguments: ["hello", "world"],
            profile: PermissionProfile(fileSystem: .fullAccess, network: .enabled))
        XCTAssertEqual(argv, ["/bin/echo", "hello", "world"])
    }

    func testReadOnlyWrapsWithSandboxExec() {
        let profile = PermissionProfile(fileSystem: .readOnly, network: .disabled)
        let argv = SandboxTransform.wrap(
            command: "/bin/sh",
            arguments: ["-c", "echo hi"],
            profile: profile)
        XCTAssertEqual(argv.first, "/usr/bin/sandbox-exec")
        XCTAssertEqual(argv[1], "-p")
        XCTAssertEqual(argv[2], SeatbeltProfileRenderer.render(profile))
        XCTAssertEqual(Array(argv.dropFirst(3)), ["/bin/sh", "-c", "echo hi"])
    }

    func testFullAccessButNetworkDisabledStillWraps() {
        // fs 放行但网络关：仍需 sandbox-exec 来 deny network
        let argv = SandboxTransform.wrap(
            command: "/usr/bin/curl",
            arguments: ["https://example.com"],
            profile: PermissionProfile(fileSystem: .fullAccess, network: .disabled))
        XCTAssertEqual(argv.first, "/usr/bin/sandbox-exec")
        XCTAssertTrue(argv[2].contains("(deny network*)"))
    }

    func testSandboxExecPathIsHardcodedAbsolute() {
        XCTAssertEqual(SandboxTransform.sandboxExecPath, "/usr/bin/sandbox-exec")
        XCTAssertTrue(SandboxTransform.sandboxExecPath.hasPrefix("/"))
    }

    func testRequiresSandbox() {
        XCTAssertFalse(SandboxTransform.requiresSandbox(
            PermissionProfile(fileSystem: .fullAccess, network: .enabled)))
        XCTAssertTrue(SandboxTransform.requiresSandbox(.readOnly))
        XCTAssertTrue(SandboxTransform.requiresSandbox(
            PermissionProfile(fileSystem: .fullAccess, network: .disabled)))
        XCTAssertTrue(SandboxTransform.requiresSandbox(
            PermissionProfile(fileSystem: .workspaceWrite(writableRoots: []), network: .enabled)))
    }
}
