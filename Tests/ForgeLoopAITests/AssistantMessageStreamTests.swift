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
}
