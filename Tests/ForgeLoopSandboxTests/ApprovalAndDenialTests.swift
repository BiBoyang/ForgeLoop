import XCTest
@testable import ForgeLoopSandbox

final class SandboxDenialHeuristicTests: XCTestCase {

    /// 正例：spike 报告 §2.1 真实样本（文件写拒绝）
    func testSpikeFileDenialSampleIsPositive() {
        let stderr = "/bin/sh: /Users/boyang/sandbox-spike-denied-73910.txt: Operation not permitted\n"
        XCTAssertTrue(SandboxDenialHeuristic.isLikelySandboxDenial(exitCode: 1, stderr: stderr))
    }

    /// 负例：非零退出但无 EPERM 文本（普通命令失败）
    func testPlainFailureWithoutEpermIsNegative() {
        XCTAssertFalse(SandboxDenialHeuristic.isLikelySandboxDenial(
            exitCode: 1, stderr: "ls: /nonexistent: No such file or directory\n"))
    }

    /// 负例：exit 0 即便含 EPERM 文本也不触发（防御误判 echo 输出）
    func testZeroExitWithEpermTextIsNegative() {
        XCTAssertFalse(SandboxDenialHeuristic.isLikelySandboxDenial(
            exitCode: 0, stderr: "Operation not permitted\n"))
    }

    /// 负例：curl exit 6 DNS 失败（网络拒绝 v1 不触发升级）
    func testCurlDnsDenialIsNegative() {
        XCTAssertFalse(SandboxDenialHeuristic.isLikelySandboxDenial(
            exitCode: 6, stderr: "curl: (6) Could not resolve host: example.com\n"))
    }

    /// 负例：空 stderr
    func testEmptyStderrIsNegative() {
        XCTAssertFalse(SandboxDenialHeuristic.isLikelySandboxDenial(exitCode: 1, stderr: ""))
    }
}

final class ApprovalPolicyTests: XCTestCase {

    func testDefaultIsOnFailure() {
        XCTAssertEqual(ApprovalPolicy.default, .onFailure)
    }

    func testCodableRoundTrip() throws {
        for policy in [ApprovalPolicy.never, .onFailure] {
            let data = try JSONEncoder().encode(policy)
            XCTAssertEqual(try JSONDecoder().decode(ApprovalPolicy.self, from: data), policy)
        }
    }
}
