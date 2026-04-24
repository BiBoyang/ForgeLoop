import XCTest
@testable import ForgeLoopCli

final class CodingTUIEscapeIntentTests: XCTestCase {
    func testEscapeIntentAbortWhenStreaming() {
        let intent = resolveEscapeIntent(isStreaming: true, hasRunningBackgroundTasks: false)
        XCTAssertEqual(intent, .abortStreaming)
    }

    func testEscapeIntentKillsBackgroundWhenIdleAndHasRunningTasks() {
        let intent = resolveEscapeIntent(isStreaming: false, hasRunningBackgroundTasks: true)
        XCTAssertEqual(intent, .killBackgroundTasks)
    }

    func testEscapeIntentClearsInputWhenIdleAndNoBackgroundTasks() {
        let intent = resolveEscapeIntent(isStreaming: false, hasRunningBackgroundTasks: false)
        XCTAssertEqual(intent, .clearInput)
    }

    func testEscapeIntentPrioritizesAbortOverBackgroundKill() {
        let intent = resolveEscapeIntent(isStreaming: true, hasRunningBackgroundTasks: true)
        XCTAssertEqual(intent, .abortStreaming)
    }
}
