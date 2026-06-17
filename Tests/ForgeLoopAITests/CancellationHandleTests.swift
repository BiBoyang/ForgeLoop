import XCTest
@testable import ForgeLoopAI

private final class Counter: @unchecked Sendable {
    var count = 0
    var reason: String?
}

final class CancellationHandleTests: XCTestCase {
    func testCancelWithNilReasonFiresLateRegisteredCallback() {
        let cancellation = CancellationHandle()
        cancellation.cancel(reason: nil)

        let expectation = expectation(description: "late-registered callback fires")
        cancellation.onCancel { reason in
            XCTAssertNil(reason)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testCancelWithReasonFiresLateRegisteredCallback() {
        let cancellation = CancellationHandle()
        cancellation.cancel(reason: "abort")

        let expectation = expectation(description: "late-registered callback fires with reason")
        cancellation.onCancel { reason in
            XCTAssertEqual(reason, "abort")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testCallbackRegisteredBeforeCancelFiresOnce() {
        let cancellation = CancellationHandle()
        let counter = Counter()

        cancellation.onCancel { reason in
            counter.count += 1
            counter.reason = reason
        }

        cancellation.cancel(reason: "stop")

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(counter.reason, "stop")
    }

    func testDoubleCancelDoesNotFireHandlersTwice() {
        let cancellation = CancellationHandle()
        let counter = Counter()

        cancellation.onCancel { _ in
            counter.count += 1
        }

        cancellation.cancel(reason: "first")
        cancellation.cancel(reason: "second")

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(cancellation.reason, "first")
    }
}
