import XCTest
@testable import ForgeLoopSandbox

final class PermissionProfileTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let profiles: [PermissionProfile] = [
            PermissionProfile(fileSystem: .readOnly, network: .disabled),
            PermissionProfile(fileSystem: .readOnly, network: .enabled),
            PermissionProfile(
                fileSystem: .workspaceWrite(writableRoots: [
                    URL(fileURLWithPath: "/repo/a"),
                    URL(fileURLWithPath: "/tmp/my dir"),
                ]),
                network: .enabled),
            PermissionProfile(fileSystem: .fullAccess, network: .enabled),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for profile in profiles {
            let data = try encoder.encode(profile)
            XCTAssertEqual(try decoder.decode(PermissionProfile.self, from: data), profile)
        }
    }

    func testReadOnlyPreset() {
        XCTAssertEqual(PermissionProfile.readOnly,
                       PermissionProfile(fileSystem: .readOnly, network: .disabled))
    }

    func testSendableConformance() {
        // 编译期验证：跨并发域传递必须可行（Sendable 检查在 Swift 6 模式下为 error）
        let profile = PermissionProfile.readOnly
        Task.detached {
            _ = profile
        }.cancel()
    }
}
