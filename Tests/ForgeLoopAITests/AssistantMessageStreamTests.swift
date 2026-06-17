import XCTest
@testable import ForgeLoopAI

final class AssistantMessageStreamTests: XCTestCase {
    func testResultAfterDone() async {
        let stream = AssistantMessageStream()
        let final = AssistantMessage.text("done")
        stream.push(.start(partial: AssistantMessage.text("")))
        stream.push(.done(reason: .endTurn, message: final))
        stream.end(final)

        var count = 0
        for await _ in stream {
            count += 1
        }

        let result = await stream.result()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(result, final)
    }

    /// 结束后再 push 的事件必须被忽略，不能破坏 messageStart -> messageEnd 闭环。
    func testPushAfterEndIsIgnored() async {
        let stream = AssistantMessageStream()
        let final = AssistantMessage.text("done")
        stream.push(.start(partial: AssistantMessage.text("")))
        stream.end(final)
        stream.push(.textDelta(contentIndex: 0, delta: "leak", partial: AssistantMessage.text("leak")))

        var events: [AssistantMessageEvent] = []
        for await event in stream {
            events.append(event)
        }

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first, .start(partial: AssistantMessage.text("")))
        let result = await stream.result()
        XCTAssertEqual(result, final)
    }

    /// 并发 push 与提前 end 必须保持稳定：结果收敛、不崩溃、事件数不超过 push 次数。
    func testConcurrentPushAndEndIsStable() async {
        for _ in 0..<50 {
            let stream = AssistantMessageStream()
            let final = AssistantMessage.text("done")
            let totalPushes = 1_000

            let pusher = Task {
                for i in 0..<totalPushes {
                    stream.push(.textDelta(contentIndex: 0, delta: "\(i)", partial: AssistantMessage.text("\(i)")))
                }
            }

            let ender = Task {
                // 让 push 与 end 有一定概率交错。
                try? await Task.sleep(nanoseconds: 200_000)
                stream.end(final)
            }

            var events: [AssistantMessageEvent] = []
            for await event in stream {
                events.append(event)
            }

            await pusher.value
            await ender.value

            XCTAssertLessThanOrEqual(events.count, totalPushes, "Stream delivered more events than were pushed")
            let result = await stream.result()
            XCTAssertEqual(result, final)
        }
    }

    /// end 并排空缓冲后，再调用 next() 必须返回 nil，且此时再 push 的事件被忽略。
    func testNextReturnsNilAfterDrainAndEnd() async {
        let stream = AssistantMessageStream()
        let final = AssistantMessage.text("done")
        stream.push(.start(partial: AssistantMessage.text("")))
        stream.end(final)

        // result() 已经返回说明 end 一定完成。
        _ = await stream.result()

        var iter = stream.makeAsyncIterator()
        while await iter.next() != nil { }

        let afterDrain = await iter.next()
        XCTAssertNil(afterDrain)

        stream.push(.textDelta(contentIndex: 0, delta: "late", partial: AssistantMessage.text("late")))
        let stillNil = await iter.next()
        XCTAssertNil(stillNil)
    }
}
