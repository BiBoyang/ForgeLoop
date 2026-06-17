import XCTest
@testable import ForgeLoopAI

final class SSEParserTests: XCTestCase {
    func testParsesSingleMessage() {
        var parser = SSEParser()
        parser.ingest("event: message\ndata: hello\n\n")
        let messages = parser.drain()

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.event, "message")
        XCTAssertEqual(messages.first?.data, "hello")
    }

    func testValueSemantics() {
        var parser1 = SSEParser()
        parser1.ingest("data: one\n\n")

        var parser2 = parser1
        parser2.ingest("data: two\n\n")

        let messages1 = parser1.drain()
        let messages2 = parser2.drain()

        XCTAssertEqual(messages1.count, 1)
        XCTAssertEqual(messages1.first?.data, "one")
        XCTAssertEqual(messages2.count, 2)
        XCTAssertEqual(messages2.map(\.data), ["one", "two"])
    }

    func testHighFrequencyIngestPreservesOrder() {
        var parser = SSEParser()
        let count = 1000
        var collected: [SSEMessage] = []

        for i in 0..<count {
            parser.ingest("data: line\(i)\n\n")
            if i % 10 == 9 {
                collected.append(contentsOf: parser.drain())
            }
        }
        collected.append(contentsOf: parser.finish())

        XCTAssertEqual(collected.count, count)
        for (index, message) in collected.enumerated() {
            XCTAssertEqual(message.data, "line\(index)")
        }
    }

    func testSendableAcrossTasks() async {
        let parser = SSEParser()
        let result = await Task {
            var local = parser
            local.ingest("data: from task\n\n")
            return local.drain()
        }.value

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.data, "from task")
    }
}
