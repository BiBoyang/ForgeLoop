import XCTest
@testable import ForgeLoopAI
@testable import ForgeLoopAgent
@testable import ForgeLoopSandbox
@testable import ForgeLoopTestSupport

/// TASK-sandbox-approval 流程测试：批准→重跑成功 / 拒绝→错误回灌 / never→不问直接败，
/// 以及 subagent 链路的沙箱覆盖（扩 scope 项）。
final class SandboxEscalationTests: XCTestCase {
    private var tempDirs: [String] = []
    private var homeFiles: [String] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(atPath: dir) }
        for file in homeFiles { try? FileManager.default.removeItem(atPath: file) }
        tempDirs = []
        homeFiles = []
        super.tearDown()
    }

    private func setupTempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandbox-escalation-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func uniqueHomeFile(_ prefix: String = "sandbox-escalation") -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let path = "\(home)/\(prefix)-\(UUID().uuidString).txt"
        homeFiles.append(path)
        return path
    }

    private func sandboxedProfile(cwd: String) -> PermissionProfile {
        let (profile, rejected) = SandboxProfileFactory.makeDefault(cwd: cwd)
        XCTAssertTrue(rejected.isEmpty)
        return profile
    }

    private actor HandlerSpy {
        private(set) var calls: [(command: String, reason: String)] = []
        var verdict: Bool
        init(verdict: Bool) { self.verdict = verdict }
        func record(_ command: String, _ reason: String) -> Bool {
            calls.append((command, reason))
            return verdict
        }
    }

    // MARK: - 批准 → 非沙箱重跑成功

    func testApprovedEscalationRerunsWithoutSandbox() async throws {
        let dir = setupTempDir()
        let target = uniqueHomeFile()
        let spy = HandlerSpy(verdict: true)

        let tool = BashTool(
            profile: sandboxedProfile(cwd: dir),
            policy: .onFailure,
            escalationHandler: { cmd, reason in await spy.record(cmd, reason) }
        )
        let result = await tool.execute(
            arguments: "{\"command\":\"echo escalated > \(target)\"}",
            cwd: dir,
            cancellation: nil
        )

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
        // handler 恰好被调一次（重跑直接走 ProcessRunner，不会再次触发升级——仅一次语义）
        let calls = await spy.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].command.contains("echo escalated"))
        XCTAssertTrue(calls[0].reason.contains("Operation not permitted"))
    }

    // MARK: - 拒绝 → 不重跑，错误回灌并附提示

    func testDeniedEscalationReturnsOriginalFailure() async throws {
        let dir = setupTempDir()
        let target = uniqueHomeFile()
        let spy = HandlerSpy(verdict: false)

        let tool = BashTool(
            profile: sandboxedProfile(cwd: dir),
            policy: .onFailure,
            escalationHandler: { cmd, reason in await spy.record(cmd, reason) }
        )
        let result = await tool.execute(
            arguments: "{\"command\":\"echo nope > \(target)\"}",
            cwd: dir,
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Operation not permitted"), result.output)
        XCTAssertTrue(result.output.contains("[sandbox]"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "拒绝后不得发生非沙箱重跑")
        let calls = await spy.calls
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - never → handler 不被调用，直接失败

    func testNeverPolicySkipsHandler() async throws {
        let dir = setupTempDir()
        let target = uniqueHomeFile()
        let spy = HandlerSpy(verdict: true)

        let tool = BashTool(
            profile: sandboxedProfile(cwd: dir),
            policy: .never,
            escalationHandler: { cmd, reason in await spy.record(cmd, reason) }
        )
        let result = await tool.execute(
            arguments: "{\"command\":\"echo nope > \(target)\"}",
            cwd: dir,
            cancellation: nil
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("[sandbox]"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        let calls = await spy.calls
        XCTAssertEqual(calls.count, 0, "policy=never 时 handler 不应被调用")
    }

    // MARK: - handler 缺失（等价 never，AppKit 默认路径）

    func testMissingHandlerFailsWithHint() async throws {
        let dir = setupTempDir()
        let target = uniqueHomeFile()
        let tool = BashTool(profile: sandboxedProfile(cwd: dir), policy: .onFailure)
        let result = await tool.execute(
            arguments: "{\"command\":\"echo nope > \(target)\"}",
            cwd: dir,
            cancellation: nil
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("[sandbox]"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    // MARK: - 非沙箱拒绝的普通失败不触发升级

    func testPlainFailureDoesNotTriggerHandler() async throws {
        let dir = setupTempDir()
        let spy = HandlerSpy(verdict: true)
        let tool = BashTool(
            profile: sandboxedProfile(cwd: dir),
            policy: .onFailure,
            escalationHandler: { cmd, reason in await spy.record(cmd, reason) }
        )
        let result = await tool.execute(
            arguments: "{\"command\":\"exit 1\"}",
            cwd: dir,
            cancellation: nil
        )
        XCTAssertTrue(result.isError)
        let calls = await spy.calls
        XCTAssertEqual(calls.count, 0, "普通失败不应触发升级询问")
    }

    // MARK: - 无沙箱 profile 时不触发升级（EPERM 文本也不升级）

    func testUnsandboxedRunNeverEscalates() async throws {
        let spy = HandlerSpy(verdict: true)
        let tool = BashTool(
            policy: .onFailure,
            escalationHandler: { cmd, reason in await spy.record(cmd, reason) }
        )
        let result = await tool.execute(
            arguments: "{\"command\":\"echo Operation not permitted >&2; exit 1\"}",
            cwd: "/tmp",
            cancellation: nil
        )
        XCTAssertTrue(result.isError)
        let calls = await spy.calls
        XCTAssertEqual(calls.count, 0, "未经沙箱执行的失败不触发升级")
    }

    // MARK: - 扩 scope 项：subagent 的 bash 同样被沙箱覆盖

    func testSubagentBashWriteOutsideCwdIsDenied() async throws {
        let dir = setupTempDir()
        let target = uniqueHomeFile("sandbox-subagent")
        let counter = StreamCallCounter()

        let toolCall = ToolCall(
            id: "call-sub-bash",
            name: "bash",
            arguments: "{\"command\":\"echo subagent-nope > \(target)\"}"
        )
        let toolMessage = AssistantMessage(content: [.toolCall(toolCall)], stopReason: .toolUse)

        let streamFn: StreamFn = { _, _, _ in
            let count = await counter.increment()
            let stream = AssistantMessageStream()
            if count == 1 {
                Task.detached {
                    stream.push(.start(partial: toolMessage))
                    stream.push(.done(reason: .toolUse, message: toolMessage))
                    stream.end(toolMessage)
                }
            } else {
                let endMessage = AssistantMessage.text("done", stopReason: .endTurn)
                Task.detached {
                    stream.push(.start(partial: endMessage))
                    stream.push(.done(reason: .endTurn, message: endMessage))
                    stream.end(endMessage)
                }
            }
            return stream
        }

        let result = try await runSubagent(
            definition: .general,
            taskPrompt: "Try to write a file to $HOME.",
            parentConfig: CodingAgentConfig(
                model: Model(id: "faux", name: "Faux", api: "faux", provider: "faux"),
                cwd: dir,
                streamFn: streamFn
            ),
            parentSessionId: "sandbox-escalation-test"
        )

        XCTAssertEqual(result.toolCalls, 1)
        let toolResults = result.messages.compactMap { message -> ToolResultMessage? in
            if case .tool(let toolResult) = message { return toolResult }
            return nil
        }
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertTrue(toolResults[0].isError)
        XCTAssertTrue(toolResults[0].output.contains("Operation not permitted"), toolResults[0].output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "subagent 的越界写必须被沙箱拒绝")
    }
}
