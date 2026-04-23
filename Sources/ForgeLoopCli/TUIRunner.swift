import Foundation
import ForgeLoopTUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum KeyEvent: Sendable, Equatable {
    case char(Character)
    case enter
    case escape
    case ctrlC
    case backspace
    case csi([UInt8])
    case up
    case down
    case paste(String)
}

public protocol InputSource: Sendable {
    func readByte() async -> UInt8?
}

public struct StandardInputSource: InputSource {
    public init() {}
    public func readByte() async -> UInt8? {
        while !Task.isCancelled {
            var byte: UInt8 = 0
            let n = read(STDIN_FILENO, &byte, 1)
            if n > 0 {
                return byte
            }
            if n < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                return nil
            }
            return nil
        }
        return nil
    }
}

// MARK: - KeyParser (actor-isolated state machine)

actor KeyParser {
    private var pendingEscTask: Task<Void, Never>?
    private var continuation: AsyncStream<KeyEvent>.Continuation?
    private var pendingUTF8Bytes: [UInt8] = []
    private let escFlushNanos: UInt64

    // Bracketed paste state
    private var isInPasteMode: Bool = false
    private var pasteBuffer: [UInt8] = []

    init(escFlushNanos: UInt64) {
        self.escFlushNanos = escFlushNanos
    }

    func bind(_ continuation: AsyncStream<KeyEvent>.Continuation) {
        self.continuation = continuation
    }

    func terminate() {
        pendingEscTask?.cancel()
        pendingEscTask = nil
        pendingUTF8Bytes.removeAll()
        isInPasteMode = false
        pasteBuffer.removeAll()
        continuation = nil
    }

    func processByte(_ byte: UInt8, from inputSource: InputSource) async {
        guard let cont = continuation else { return }

        if isInPasteMode {
            await processByteInPasteMode(byte, from: inputSource, cont: cont)
            return
        }

        // If an ESC flush timer is pending, cancel it and decide what this byte means.
        if pendingEscTask != nil {
            pendingEscTask?.cancel()
            pendingEscTask = nil

            if byte == 0x5B { // '[' -> CSI sequence
                let csiBytes = await readCSI(from: inputSource, prefix: [0x1B, 0x5B])
                handleCSI(csiBytes, cont: cont)
                return
            }

            // Not a CSI: emit the pending escape, then fall through to handle current byte.
            cont.yield(.escape)
        }

        switch byte {
        case 0x03:
            flushPendingUTF8(cont)
            cont.yield(.ctrlC)
        case 0x0D, 0x0A:
            flushPendingUTF8(cont)
            cont.yield(.enter)
        case 0x1B:
            flushPendingUTF8(cont)
            let flushNanos = escFlushNanos
            pendingEscTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: flushNanos)
                guard let self = self else { return }
                await self.flushEscape()
            }
        case 0x7F:
            flushPendingUTF8(cont)
            cont.yield(.backspace)
        default:
            emitTextByte(byte, continuation: cont)
        }
    }

    // MARK: - Bracketed Paste

    private func processByteInPasteMode(
        _ byte: UInt8,
        from inputSource: InputSource,
        cont: AsyncStream<KeyEvent>.Continuation
    ) async {
        if byte == 0x1B {
            guard let nextByte = await inputSource.readByte() else {
                pasteBuffer.append(0x1B)
                return
            }
            if nextByte == 0x5B {
                let csiBytes = await readCSI(from: inputSource, prefix: [0x1B, 0x5B])
                if csiBytes == bracketedPasteEnd {
                    let content = String(bytes: pasteBuffer, encoding: .utf8)
                        ?? String(decoding: pasteBuffer, as: UTF8.self)
                    pasteBuffer.removeAll()
                    isInPasteMode = false
                    cont.yield(.paste(content))
                    return
                } else {
                    pasteBuffer.append(contentsOf: csiBytes)
                    return
                }
            } else {
                pasteBuffer.append(0x1B)
                pasteBuffer.append(nextByte)
                return
            }
        }
        pasteBuffer.append(byte)
    }

    private func readCSI(from inputSource: InputSource, prefix: [UInt8]) async -> [UInt8] {
        var csiBytes = prefix
        var finalByte: UInt8 = 0
        repeat {
            guard let b = await inputSource.readByte() else { break }
            csiBytes.append(b)
            finalByte = b
        } while !(0x40...0x7E).contains(finalByte)
        return csiBytes
    }

    private let bracketedPasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // ESC[200~
    private let bracketedPasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]   // ESC[201~
    private let arrowUp: [UInt8] = [0x1B, 0x5B, 0x41]                                 // ESC[A
    private let arrowDown: [UInt8] = [0x1B, 0x5B, 0x42]                               // ESC[B

    private func handleCSI(_ csiBytes: [UInt8], cont: AsyncStream<KeyEvent>.Continuation) {
        switch csiBytes {
        case bracketedPasteStart:
            isInPasteMode = true
            pasteBuffer.removeAll()
        case arrowUp:
            cont.yield(.up)
        case arrowDown:
            cont.yield(.down)
        default:
            cont.yield(.csi(csiBytes))
        }
    }

    // MARK: - ESC Flush

    private func flushEscape() {
        guard !Task.isCancelled else { return }
        pendingEscTask = nil
        continuation?.yield(.escape)
    }

    // MARK: - UTF-8 Text

    private func emitTextByte(_ byte: UInt8, continuation: AsyncStream<KeyEvent>.Continuation) {
        if pendingUTF8Bytes.isEmpty && byte <= 0x7F {
            continuation.yield(.char(Character(UnicodeScalar(byte))))
            return
        }

        pendingUTF8Bytes.append(byte)

        if let decoded = String(bytes: pendingUTF8Bytes, encoding: .utf8) {
            for character in decoded {
                continuation.yield(.char(character))
            }
            pendingUTF8Bytes.removeAll()
            return
        }

        let expectedLength = expectedUTF8Length(for: pendingUTF8Bytes[0])
        if expectedLength == 0 {
            flushPendingUTF8(continuation)
            return
        }

        if pendingUTF8Bytes.count >= expectedLength {
            flushPendingUTF8(continuation)
        }
    }

    private func expectedUTF8Length(for leadingByte: UInt8) -> Int {
        if leadingByte <= 0x7F { return 1 }
        if (0xC2...0xDF).contains(leadingByte) { return 2 }
        if (0xE0...0xEF).contains(leadingByte) { return 3 }
        if (0xF0...0xF4).contains(leadingByte) { return 4 }
        return 0
    }

    private func flushPendingUTF8(_ continuation: AsyncStream<KeyEvent>.Continuation) {
        guard !pendingUTF8Bytes.isEmpty else { return }
        let fallback = String(decoding: pendingUTF8Bytes, as: UTF8.self)
        for character in fallback {
            continuation.yield(.char(character))
        }
        pendingUTF8Bytes.removeAll()
    }
}

// MARK: - TUIRunner

public final class TUIRunner: @unchecked Sendable {
    public let tui: TUI

    private let inputSource: InputSource
    private var originalTermios: termios?
    private var originalInputFlags: CInt?
    private let escFlushNanos: UInt64

    public init(inputSource: InputSource? = nil, escFlushNanos: UInt64? = nil) {
        self.inputSource = inputSource ?? StandardInputSource()
        self.escFlushNanos = escFlushNanos ?? 50_000_000
        let isTTY = isatty(STDOUT_FILENO) == 1 && isatty(STDIN_FILENO) == 1
        self.tui = TUI(isTTY: isTTY)
    }

    deinit {
        restoreTerminal()
    }

    public func run() async -> AsyncStream<KeyEvent> {
        let isStandardInput = inputSource is StandardInputSource
        if isStandardInput && isatty(STDIN_FILENO) != 1 {
            return AsyncStream { $0.finish() }
        }

        if isStandardInput {
            var current = termios()
            guard tcgetattr(STDIN_FILENO, &current) == 0 else {
                return AsyncStream { $0.finish() }
            }

            let currentFlags = fcntl(STDIN_FILENO, F_GETFL)
            guard currentFlags >= 0 else {
                return AsyncStream { $0.finish() }
            }
            guard fcntl(STDIN_FILENO, F_SETFL, currentFlags | O_NONBLOCK) >= 0 else {
                return AsyncStream { $0.finish() }
            }

            originalTermios = current
            originalInputFlags = currentFlags
            var raw = current

            raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
            raw.c_iflag &= ~tcflag_t(IXON | ICRNL | INLCR | IGNCR)
            raw.c_oflag &= ~tcflag_t(OPOST)
            withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
                ptr.withMemoryRebound(to: cc_t.self, capacity: 20) { arr in
                    arr[Int(VMIN)] = 1
                    arr[Int(VTIME)] = 0
                }
            }
            raw.c_iflag = withUTF8EraseFlag(raw.c_iflag)

            guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
                restoreTerminal()
                return AsyncStream { $0.finish() }
            }
        }

        let parser = KeyParser(escFlushNanos: escFlushNanos)

        return AsyncStream { [inputSource] continuation in
            let bindTask = Task {
                await parser.bind(continuation)
            }

            let readTask = Task { [weak self] in
                _ = await bindTask.value

                defer {
                    if isStandardInput {
                        self?.restoreTerminal()
                    }
                }

                while !Task.isCancelled {
                    guard let byte = await inputSource.readByte() else { break }
                    await parser.processByte(byte, from: inputSource)
                }
            }

            continuation.onTermination = { _ in
                readTask.cancel()
                Task {
                    await parser.terminate()
                }
            }
        }
    }

    // MARK: - Terminal

    private func restoreTerminal() {
        guard var original = originalTermios else { return }
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        originalTermios = nil
        if let flags = originalInputFlags {
            _ = fcntl(STDIN_FILENO, F_SETFL, flags)
            originalInputFlags = nil
        }
    }
}

public func hasUTF8EraseFlag(_ inputFlags: tcflag_t) -> Bool {
    (inputFlags & tcflag_t(IUTF8)) != 0
}

public func withUTF8EraseFlag(_ inputFlags: tcflag_t) -> tcflag_t {
    inputFlags | tcflag_t(IUTF8)
}
