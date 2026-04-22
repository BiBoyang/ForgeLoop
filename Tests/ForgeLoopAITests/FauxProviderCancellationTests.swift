import XCTest
@testable import ForgeLoopAI

final class FauxProviderCancellationTests: XCTestCase {
    private var testModel: Model {
        Model(id: "faux-test", name: "Faux Test", api: "faux", provider: "faux")
    }

    private var testContext: Context {
        Context(systemPrompt: "", messages: [.user(UserMessage(text: "hello"))])
    }

    // MARK: - 1) 取消时事件序列包含 error + end，没有 done

    func testCancellationEmitsAbortedErrorAndEnds() async throws {
        let provider = FauxProvider(tokenDelayNanos: 100_000_000) // 100ms/chunk
        let handle = CancellationHandle()
        let options = StreamOptions(cancellation: handle)

        let stream = provider.stream(model: testModel, context: testContext, options: options)

        // 等待流开始产生 chunk
        try await Task.sleep(nanoseconds: 150_000_000)

        handle.cancel(reason: "test abort")

        var events: [AssistantMessageEvent] = []
        for await event in stream {
            events.append(event)
        }

        let hasError = events.contains {
            if case .error(let reason, _) = $0, reason == .aborted { return true }
            return false
        }
        XCTAssertTrue(hasError, "Expected aborted error event")

        let hasDone = events.contains {
            if case .done = $0 { return true }
            return false
        }
        XCTAssertFalse(hasDone, "Should not emit done after cancellation")

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .aborted)
        XCTAssertEqual(result.errorMessage, "Request was aborted")
    }

    // MARK: - 2) 取消后不出现 done（在循环结束后取消也要覆盖）

    func testCancellationDoesNotEmitDoneAfterError() async throws {
        let provider = FauxProvider(tokenDelayNanos: 50_000_000) // 50ms/chunk
        let handle = CancellationHandle()
        let options = StreamOptions(cancellation: handle)

        let stream = provider.stream(model: testModel, context: testContext, options: options)

        // 等大部分 chunk 已发出，接近末尾时取消
        try await Task.sleep(nanoseconds: 200_000_000)

        handle.cancel(reason: "late abort")

        var eventTypes: [String] = []
        for await event in stream {
            switch event {
            case .start: eventTypes.append("start")
            case .textStart: eventTypes.append("textStart")
            case .textDelta: eventTypes.append("textDelta")
            case .textEnd: eventTypes.append("textEnd")
            case .done: eventTypes.append("done")
            case .error: eventTypes.append("error")
            }
        }

        XCTAssertTrue(eventTypes.contains("error"), "Expected error event")
        XCTAssertFalse(eventTypes.contains("done"), "Should not contain done after cancellation")
        // 确保 end 只出现一次（由 for-await 终止表示）
    }

    // MARK: - 3) 非取消场景保持现有 done 路径

    func testNonCancelledStreamStillEndsWithDone() async throws {
        let provider = FauxProvider(tokenDelayNanos: 10_000_000) // 10ms/chunk
        let options = StreamOptions()

        let stream = provider.stream(model: testModel, context: testContext, options: options)

        var events: [AssistantMessageEvent] = []
        for await event in stream {
            events.append(event)
        }

        let hasDone = events.contains {
            if case .done = $0 { return true }
            return false
        }
        XCTAssertTrue(hasDone, "Expected done event in non-cancelled stream")

        let hasError = events.contains {
            if case .error = $0 { return true }
            return false
        }
        XCTAssertFalse(hasError, "Should not have error in non-cancelled stream")

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .endTurn)
        XCTAssertNil(result.errorMessage)
    }

    // MARK: - 4) 取消时保留已产生的部分输出

    func testCancellationPreservesPartialOutput() async throws {
        let provider = FauxProvider(tokenDelayNanos: 100_000_000)
        let handle = CancellationHandle()
        let options = StreamOptions(cancellation: handle)

        let stream = provider.stream(model: testModel, context: testContext, options: options)

        // 等至少一个 chunk 发出
        try await Task.sleep(nanoseconds: 150_000_000)

        handle.cancel(reason: "abort")

        for await _ in stream {}

        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .aborted)

        let text = result.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text }
            return nil
        }.joined()
        XCTAssertFalse(text.isEmpty, "Aborted message should retain partial text")
    }
}
