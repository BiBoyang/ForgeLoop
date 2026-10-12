import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopSandbox

/// TASK-sandbox-wire 集成测试：默认 profile（workspaceWrite(cwd) + 断网）下，
/// 前台 BashTool 与 BackgroundTaskManager 统一经 SandboxTransform 包装。
///
/// 拒绝特征依据 notes/sandbox-spike-report.md §2 实测：
/// 文件写拒绝 = 非零退出 + stderr `Operation not permitted`，目标文件未创建。
/// 网络项不测（本机代理 env 会透传进沙箱污染判定，spike 踩坑 2）。
final class SandboxIntegrationTests: XCTestCase {
    private var tempDirs: [String] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(atPath: dir)
        }
        tempDirs = []
        super.tearDown()
    }

    private func setupTempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-wire-\(UUID().uuidString)")
            .path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func defaultProfile(cwd: String) -> PermissionProfile {
        let (profile, rejected) = SandboxProfileFactory.makeDefault(cwd: cwd)
        XCTAssertTrue(rejected.isEmpty, "temp dir should be a valid writable root: \(rejected)")
        XCTAssertEqual(profile, PermissionProfile(
            fileSystem: .workspaceWrite(writableRoots: [URL(fileURLWithPath: cwd)]),
            network: .disabled))
        return profile
    }

    // MARK: - 前台 BashTool

    func testSandboxedPipeCommandExecutes() async throws {
        let dir = setupTempDir()
        let tool = BashTool(profile: defaultProfile(cwd: dir))
        let result = await tool.execute(
            arguments: "{\"command\":\"printf 'a\\nb\\n' | head -1\"}",
            cwd: dir,
            cancellation: nil
        )
        XCTAssertFalse(result.isError, result.output)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "a")
    }

    func testSandboxedWriteToCwdSucceeds() async throws {
        let dir = setupTempDir()
        let tool = BashTool(profile: defaultProfile(cwd: dir))
        let result = await tool.execute(
            arguments: "{\"command\":\"echo data > wire-ok.txt\"}",
            cwd: dir,
            cancellation: nil
        )
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/wire-ok.txt"))
    }

    func testSandboxedWriteOutsideCwdIsDenied() async throws {
        let dir = setupTempDir()
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let deniedPath = "\(home)/sandbox-wire-denied-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: deniedPath) }

        let tool = BashTool(profile: defaultProfile(cwd: dir))
        let result = await tool.execute(
            arguments: "{\"command\":\"echo nope > \(deniedPath)\"}",
            cwd: dir,
            cancellation: nil
        )
        // spike 实测特征：非零退出 + stderr "Operation not permitted"，目标未创建
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Operation not permitted"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deniedPath))
    }

    func testSandboxedReadEtcHostsSucceeds() async throws {
        let dir = setupTempDir()
        let tool = BashTool(profile: defaultProfile(cwd: dir))
        let result = await tool.execute(
            arguments: "{\"command\":\"cat /etc/hosts\"}",
            cwd: dir,
            cancellation: nil
        )
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("localhost"))
    }

    // MARK: - 后台 BackgroundTaskManager

    /// 轮询直到后台任务结束（running → 终态），避免裸 sleep 抖动。
    private func waitForCompletion(_ manager: BackgroundTaskManager, id: String) async -> BackgroundTaskRecord {
        for _ in 0..<200 {
            let records = await manager.status(id: id)
            if let record = records.first, record.status != .running {
                return record
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        XCTFail("background task \(id) did not finish in time")
        return await manager.status(id: id).first!
    }

    func testSandboxedBackgroundWriteToCwdSucceeds() async throws {
        let dir = setupTempDir()
        let manager = BackgroundTaskManager(profile: defaultProfile(cwd: dir))
        let id = try await manager.start(command: "echo bg > bg-ok.txt", cwd: dir)
        let record = await waitForCompletion(manager, id: id)
        XCTAssertEqual(record.status, .success, record.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/bg-ok.txt"))
    }

    func testSandboxedBackgroundWriteOutsideCwdIsDenied() async throws {
        let dir = setupTempDir()
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let deniedPath = "\(home)/sandbox-wire-bg-denied-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: deniedPath) }

        let manager = BackgroundTaskManager(profile: defaultProfile(cwd: dir))
        let id = try await manager.start(command: "echo nope > \(deniedPath)", cwd: dir)
        let record = await waitForCompletion(manager, id: id)
        XCTAssertEqual(record.status, .failed)
        XCTAssertTrue(record.output.contains("Operation not permitted"), record.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deniedPath))
    }

    func testSandboxedBackgroundPipeCommandExecutes() async throws {
        let dir = setupTempDir()
        let manager = BackgroundTaskManager(profile: defaultProfile(cwd: dir))
        let id = try await manager.start(command: "printf 'x\\ny\\n' | tail -1", cwd: dir)
        let record = await waitForCompletion(manager, id: id)
        XCTAssertEqual(record.status, .success, record.output)
        XCTAssertTrue(record.output.contains("y"), record.output)
    }

    // MARK: - SandboxProfileFactory 校验策略

    func testFactoryRejectsSymlinkRoot() {
        let (valid, rejected) = SandboxProfileFactory.validateWritableRoots([URL(fileURLWithPath: "/tmp")])
        // /tmp 是指向 /private/tmp 的 symlink（macOS 实测）
        XCTAssertTrue(valid.isEmpty)
        XCTAssertEqual(rejected.first?.reason, "path is a symlink")
    }

    func testFactoryRejectsMissingRoot() {
        let (valid, rejected) = SandboxProfileFactory.validateWritableRoots(
            [URL(fileURLWithPath: "/nonexistent/sandbox-wire-deadbeef")])
        XCTAssertTrue(valid.isEmpty)
        XCTAssertEqual(rejected.first?.reason, "path does not exist")
    }

    func testFactoryRejectsControlCharacterRoot() {
        let (valid, rejected) = SandboxProfileFactory.validateWritableRoots(
            [URL(fileURLWithPath: "/tmp/evil\n(deny default)")])
        XCTAssertTrue(valid.isEmpty)
        XCTAssertEqual(rejected.first?.reason, "path contains control characters")
    }

    func testFactoryRejectsFileRoot() throws {
        let dir = setupTempDir()
        let file = "\(dir)/a-file.txt"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        let (valid, rejected) = SandboxProfileFactory.validateWritableRoots([URL(fileURLWithPath: file)])
        XCTAssertTrue(valid.isEmpty)
        XCTAssertEqual(rejected.first?.reason, "path is not a directory")
    }

    func testFactoryAcceptsRealDirectory() {
        let dir = setupTempDir()
        let (valid, rejected) = SandboxProfileFactory.validateWritableRoots([URL(fileURLWithPath: dir)])
        XCTAssertEqual(valid, [URL(fileURLWithPath: dir)])
        XCTAssertTrue(rejected.isEmpty)
    }

    func testFactoryDegradesToReadOnlyWhenAllRootsRejected() {
        let (profile, rejected) = SandboxProfileFactory.makeDefault(cwd: "/nonexistent/sandbox-wire-deadbeef")
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(profile, PermissionProfile(fileSystem: .readOnly, network: .disabled))
    }
}
