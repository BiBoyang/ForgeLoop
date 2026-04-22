import Foundation
import ForgeLoopTUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class TUIRunner: @unchecked Sendable {
    let tui = TUI()

    private var patchedTermios: termios?

    deinit {
        restoreIfNeeded()
    }

    func run() async {
        enableUTF8EraseIfPossible()
    }

    private func enableUTF8EraseIfPossible() {
        guard isatty(STDIN_FILENO) == 1 else { return }

        var current = termios()
        guard tcgetattr(STDIN_FILENO, &current) == 0 else { return }
        guard !hasUTF8EraseFlag(current.c_iflag) else { return }

        var updated = current
        updated.c_iflag = withUTF8EraseFlag(updated.c_iflag)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &updated) == 0 else { return }

        patchedTermios = current
    }

    private func restoreIfNeeded() {
        guard var original = patchedTermios else { return }
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
        patchedTermios = nil
    }
}

func hasUTF8EraseFlag(_ inputFlags: tcflag_t) -> Bool {
    (inputFlags & tcflag_t(IUTF8)) != 0
}

func withUTF8EraseFlag(_ inputFlags: tcflag_t) -> tcflag_t {
    inputFlags | tcflag_t(IUTF8)
}
