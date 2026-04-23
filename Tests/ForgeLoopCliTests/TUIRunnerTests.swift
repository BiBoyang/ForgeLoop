import XCTest
@testable import ForgeLoopCli

// MARK: - Mock Input Source

actor MockInputSource: InputSource {
    private var bytes: [UInt8] = []
    private var waiters: [CheckedContinuation<UInt8?, Never>] = []

    func append(_ newBytes: [UInt8]) {
        bytes.append(contentsOf: newBytes)
        flushWaiters()
    }

    func append(_ string: String) {
        append(Array(string.utf8))
    }

    func readByte() async -> UInt8? {
        if let byte = bytes.first {
            bytes.removeFirst()
            return byte
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func flushWaiters() {
        while !waiters.isEmpty && !bytes.isEmpty {
            let waiter = waiters.removeFirst()
            let byte = bytes.removeFirst()
            waiter.resume(returning: byte)
        }
    }
}

actor TestInputSource: InputSource {
    private var bytes: [UInt8] = []

    func append(_ newBytes: [UInt8]) {
        bytes.append(contentsOf: newBytes)
    }

    func readByte() async -> UInt8? {
        if !bytes.isEmpty {
            return bytes.removeFirst()
        }
        return nil
    }
}

// MARK: - Tests

final class TUIRunnerTests: XCTestCase {

    // MARK: - UTF-8 Erase (existing)

    func testWithUTF8EraseFlagSetsBit() {
        let flags: tcflag_t = 0
        let updated = withUTF8EraseFlag(flags)
        XCTAssertTrue(hasUTF8EraseFlag(updated))
    }

    func testWithUTF8EraseFlagIsIdempotent() {
        let initial = withUTF8EraseFlag(0)
        let updated = withUTF8EraseFlag(initial)
        XCTAssertEqual(initial, updated)
        XCTAssertTrue(hasUTF8EraseFlag(updated))
    }

    // MARK: - Key Events

    func testEnterKey() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        await mock.append([0x0D])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            break
        }

        XCTAssertEqual(collected, [.enter])
    }

    func testCtrlCKey() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        await mock.append([0x03])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            break
        }

        XCTAssertEqual(collected, [.ctrlC])
    }

    func testBackspaceKey() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        await mock.append([0x7F])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            break
        }

        XCTAssertEqual(collected, [.backspace])
    }

    func testCharKeys() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        await mock.append("abc")

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            if collected.count == 3 { break }
        }

        XCTAssertEqual(collected, [.char("a"), .char("b"), .char("c")])
    }

    // MARK: - Escape / CSI

    func testEscapeKeyAlone() async throws {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        await mock.append([0x1B])
        // Wait for flush timer (5ms + margin)
        try await Task.sleep(nanoseconds: 10_000_000)

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            break
        }

        XCTAssertEqual(collected, [.escape])
    }

    func testArrowUp() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        // ESC [ A (arrow up)
        await mock.append([0x1B, 0x5B, 0x41])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            break
        }

        XCTAssertEqual(collected, [.up])
    }

    func testArrowDown() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        // ESC [ B (arrow down)
        await mock.append([0x1B, 0x5B, 0x42])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            break
        }

        XCTAssertEqual(collected, [.down])
    }

    func testUnknownCSISequence() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        // ESC [ 3 ~ (delete key on some terminals) — not up/down/paste
        await mock.append([0x1B, 0x5B, 0x33, 0x7E])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            break
        }

        XCTAssertEqual(collected, [.csi([0x1B, 0x5B, 0x33, 0x7E])])
    }

    func testFragmentedEscThenCSI() async throws {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        // Send ESC, wait for flush, then send [ A
        await mock.append([0x1B])
        try await Task.sleep(nanoseconds: 10_000_000)
        await mock.append([0x5B, 0x41])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            if collected.count == 3 { break }
        }

        // ESC flushed as escape, then [ and A as individual chars
        XCTAssertEqual(collected, [.escape, .char("["), .char("A")])
    }

    func testEscFollowedByNonCSI() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        // ESC followed by 'x' (not [)
        await mock.append([0x1B, UInt8(ascii: "x")])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            if collected.count == 2 { break }
        }

        XCTAssertEqual(collected, [.escape, .char("x")])
    }

    // MARK: - Input Sequence Parsing

    func testMixedSequence() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        // h e l l o Enter
        await mock.append("hello")
        await mock.append([0x0D])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            if collected.count == 6 { break }
        }

        XCTAssertEqual(collected, [
            .char("h"), .char("e"), .char("l"), .char("l"), .char("o"), .enter
        ])
    }

    func testUTF8MultibyteCharacters() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        await mock.append("你好")

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            if collected.count == 2 { break }
        }

        XCTAssertEqual(collected, [.char("你"), .char("好")])
    }

    // MARK: - Termination

    func testKeyParserTerminateCancelsPendingEsc() async throws {
        // Directly test the actor-isolated KeyParser to verify terminate()
        // cancels the pending ESC flush timer, preventing .escape from being yielded.
        let source = TestInputSource()
        let parser = KeyParser(escFlushNanos: 5_000_000)

        let (stream, continuation) = AsyncStream.makeStream(of: KeyEvent.self)
        await parser.bind(continuation)

        // Send ESC to start the flush timer
        await parser.processByte(0x1B, from: source)

        // Immediately terminate before the 5ms flush window expires
        await parser.terminate()

        // Wait past the flush window
        try await Task.sleep(nanoseconds: 10_000_000)

        continuation.finish()

        var collected: [KeyEvent] = []
        for await event in stream {
            collected.append(event)
        }

        XCTAssertEqual(collected, [], "terminate() must cancel pending ESC timer")
    }

    func testKeyParserTerminateThenNoMoreEvents() async throws {
        // Verify that after terminate(), further bytes produce no events.
        let source = TestInputSource()
        let parser = KeyParser(escFlushNanos: 5_000_000)

        let (stream, continuation) = AsyncStream.makeStream(of: KeyEvent.self)
        await parser.bind(continuation)

        await parser.processByte(UInt8(ascii: "a"), from: source)
        await parser.terminate()
        await parser.processByte(UInt8(ascii: "b"), from: source)

        continuation.finish()

        var collected: [KeyEvent] = []
        for await event in stream {
            collected.append(event)
        }

        XCTAssertEqual(collected, [.char("a")], "Events after terminate() must be dropped")
    }

    // MARK: - TUI Configuration

    func testTUIRunnerCreatesTUI() {
        let runner = TUIRunner()
        XCTAssertNotNil(runner.tui)
    }

    func testTUIRunnerWithMockInputCreatesTUI() {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock)
        XCTAssertNotNil(runner.tui)
    }

    // MARK: - Bracketed Paste

    func testBracketedPasteBasic() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        // ESC[200~helloESC[201~
        await mock.append([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
        await mock.append("hello")
        await mock.append([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            if collected.count == 1 { break }
        }

        XCTAssertEqual(collected, [.paste("hello")])
    }

    func testBracketedPasteWithNewlines() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        // ESC[200~hello\nworldESC[201~
        await mock.append([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
        await mock.append("hello\nworld")
        await mock.append([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            if collected.count == 1 { break }
        }

        XCTAssertEqual(collected, [.paste("hello\nworld")])
    }

    func testBracketedPasteWithEscInside() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        // ESC[200~ESC[AESC[201~ — inner ESC[A should be part of paste content
        await mock.append([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
        await mock.append([0x1B, 0x5B, 0x41])
        await mock.append([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            if collected.count == 1 { break }
        }

        XCTAssertEqual(collected, [.paste("\u{1B}[A")])
    }

    func testEscFlushNotInterferedByArrowKeys() async throws {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        // Send ESC alone, wait for flush timer
        await mock.append([0x1B])
        try await Task.sleep(nanoseconds: 10_000_000)

        // Then send [ A (should be parsed as separate chars, not arrow up)
        await mock.append([0x5B, 0x41])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            if collected.count == 3 { break }
        }

        XCTAssertEqual(collected, [.escape, .char("["), .char("A")])
    }

    func testKeyParserTerminateDuringPaste() async throws {
        // Verify terminate() cancels bracketed paste mode.
        let source = TestInputSource()
        let parser = KeyParser(escFlushNanos: 5_000_000)

        let (stream, continuation) = AsyncStream.makeStream(of: KeyEvent.self)
        await parser.bind(continuation)

        // Pre-fill source with CSI parameters so readCSI can consume the full start sequence
        await source.append([0x32, 0x30, 0x30, 0x7E, 0x61]) // 200~a

        // Start bracketed paste: ESC[200~
        await parser.processByte(0x1B, from: source)
        await parser.processByte(0x5B, from: source) // readCSI reads 2,0,0,~

        // Now in paste mode; 'a' goes to paste buffer
        await parser.processByte(0x61, from: source)

        // Terminate should clean up paste state
        await parser.terminate()

        // Send more bytes — should produce no events because continuation is nil
        await source.append([0x62])
        await parser.processByte(0x62, from: source)

        continuation.finish()

        var collected: [KeyEvent] = []
        for await event in stream {
            collected.append(event)
        }

        XCTAssertEqual(collected, [], "terminate() must cancel paste mode")
    }

    func testFragmentedBracketedPaste() async {
        let mock = MockInputSource()
        let runner = TUIRunner(inputSource: mock, escFlushNanos: 5_000_000)
        let events = await runner.run()

        // Send start sequence fragmented
        await mock.append([0x1B])
        await mock.append([0x5B, 0x32])
        await mock.append([0x30, 0x30, 0x7E])
        await mock.append("x")
        // Send end sequence fragmented
        await mock.append([0x1B, 0x5B])
        await mock.append([0x32, 0x30, 0x31, 0x7E])

        var collected: [KeyEvent] = []
        for await event in events {
            collected.append(event)
            if collected.count == 1 { break }
        }

        XCTAssertEqual(collected, [.paste("x")])
    }
}
