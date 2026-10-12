import XCTest
@testable import ForgeLoopSandbox

final class SeatbeltProfileRendererTests: XCTestCase {

    // MARK: - 三档 fs 渲染快照

    func testReadOnlyNetworkDisabledSnapshot() {
        let sbpl = SeatbeltProfileRenderer.render(
            PermissionProfile(fileSystem: .readOnly, network: .disabled))
        XCTAssertEqual(sbpl, Self.readOnlyBase)
        XCTAssertFalse(sbpl.contains("allow network"))
        XCTAssertFalse(sbpl.contains("workspaceWrite placeholder"))
    }

    func testReadOnlyNetworkEnabledAppendsNetworkAllow() {
        let sbpl = SeatbeltProfileRenderer.render(
            PermissionProfile(fileSystem: .readOnly, network: .enabled))
        XCTAssertEqual(sbpl, Self.readOnlyBase + "(allow network*)\n")
    }

    func testWorkspaceWriteMultipleRootsSnapshot() {
        // 不存在的路径 realpath 失败 → 回退原样，保证快照确定性
        let profile = PermissionProfile(
            fileSystem: .workspaceWrite(writableRoots: [
                URL(fileURLWithPath: "/repo/alpha"),
                URL(fileURLWithPath: "/repo/beta"),
            ]),
            network: .disabled)
        let sbpl = SeatbeltProfileRenderer.render(profile)
        XCTAssertEqual(sbpl, Self.readOnlyBase + """
            (allow file-read* file-write* (subpath "/repo/alpha"))
            (allow file-read* file-write* (subpath "/repo/beta"))

            """)
    }

    func testFullAccessNetworkEnabledIsAllowDefault() {
        let sbpl = SeatbeltProfileRenderer.render(
            PermissionProfile(fileSystem: .fullAccess, network: .enabled))
        XCTAssertEqual(sbpl, "(version 1)\n(allow default)\n")
    }

    func testFullAccessNetworkDisabledDeniesNetwork() {
        let sbpl = SeatbeltProfileRenderer.render(
            PermissionProfile(fileSystem: .fullAccess, network: .disabled))
        XCTAssertEqual(sbpl, "(version 1)\n(allow default)\n(deny network*)\n")
    }

    // MARK: - 转义

    func testEscapesBackslashAndQuote() {
        XCTAssertEqual(SeatbeltProfileRenderer.escape(#"/tmp/we"ird\path"#),
                       #"/tmp/we\"ird\\path"#)
    }

    func testWorkspaceWritePathWithSpaceAndQuoteIsEscaped() {
        let profile = PermissionProfile(
            fileSystem: .workspaceWrite(writableRoots: [
                URL(fileURLWithPath: "/tmp/my dir"),
                URL(fileURLWithPath: "/tmp/we\"ird"),
            ]),
            network: .disabled)
        let sbpl = SeatbeltProfileRenderer.render(profile)
        XCTAssertTrue(sbpl.contains(#"(subpath "/tmp/my dir")"#))
        XCTAssertTrue(sbpl.contains(#"(subpath "/tmp/we\"ird")"#))
    }

    // MARK: - firmlink canonicalize（上游实测：/var → /private/var 必须 realpath）

    func testCanonicalizeResolvesVarFirmlink() {
        XCTAssertEqual(SeatbeltProfileRenderer.canonicalize("/var/tmp"), "/private/var/tmp")
        XCTAssertEqual(SeatbeltProfileRenderer.canonicalize("/tmp"), "/private/tmp")
    }

    func testWorkspaceWriteCanonicalizesFirmlinkRoot() {
        let profile = PermissionProfile(
            fileSystem: .workspaceWrite(writableRoots: [URL(fileURLWithPath: "/var/tmp")]),
            network: .disabled)
        let sbpl = SeatbeltProfileRenderer.render(profile)
        // 注意 base 骨架的临时目录条目本就含 (subpath "/var/tmp")，
        // 这里断言的是 writable-root 行本身已被 canonicalize
        XCTAssertTrue(sbpl.contains(#"(allow file-read* file-write* (subpath "/private/var/tmp"))"#))
        XCTAssertFalse(sbpl.contains(#"(allow file-read* file-write* (subpath "/var/tmp"))"#))
    }

    func testCanonicalizeFallbackForMissingPath() {
        let missing = "/nonexistent/spike-deadbeef"
        XCTAssertEqual(SeatbeltProfileRenderer.canonicalize(missing), missing)
    }

    // MARK: - base 骨架不变量

    func testBaseSkeletonStartsWithDenyDefault() {
        let sbpl = SeatbeltProfileRenderer.render(
            PermissionProfile(fileSystem: .readOnly, network: .disabled))
        XCTAssertTrue(sbpl.hasPrefix("(version 1)\n(deny default)\n"))
        XCTAssertTrue(sbpl.contains("(allow file-read*)\n"))  // 全局只读
        XCTAssertTrue(sbpl.contains(#"(path "/dev/null")"#))
    }

    // MARK: - 快照常量

    /// 与 notes/sandbox-spike-report.md §3 模板逐项一致。
    private static let readOnlyBase = """
    (version 1)
    (deny default)
    (allow process-exec)
    (allow process-fork)
    (allow signal (target same-sandbox))
    (allow process-info* (target same-sandbox))
    (allow sysctl-read)
    (allow mach-lookup)
    (allow ipc-posix-shm-read-data ipc-posix-shm-write-data)
    (allow pseudo-tty)
    (allow file-read*)
    (allow file-read* file-test-existence file-write*
        (subpath "/tmp")
        (subpath "/private/tmp")
        (subpath "/var/tmp")
        (subpath "/private/var/tmp"))
    (allow file-write-data
      (require-all
        (path "/dev/null")
        (vnode-type CHARACTER-DEVICE)))

    """
}
