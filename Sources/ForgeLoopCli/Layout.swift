import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct TerminalSize: Sendable, Equatable {
    let rows: Int
    let columns: Int
}

func getTerminalSize() -> TerminalSize? {
    var ws = winsize()
    guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0 else { return nil }
    return TerminalSize(rows: Int(ws.ws_row), columns: Int(ws.ws_col))
}

struct Layout: Sendable {
    var header: [String] = []
    var transcript: [String] = []
    var queue: [String] = []
    var status: [String] = []
    var input: [String] = []

    /// 若设置，表示 transcript 中需要完整保留的行范围（如正在 streaming 的 block）。
    /// LayoutRenderer 在预算裁剪时会优先保证该范围不被从中间静默截断。
    var pinnedTranscriptRange: Range<Int>? = nil
}

struct LayoutConfig: Sendable {
    let terminalHeight: Int
    let terminalWidth: Int
    let showHeader: Bool

    init(terminalHeight: Int = 24, terminalWidth: Int = 80, showHeader: Bool = true) {
        self.terminalHeight = terminalHeight
        self.terminalWidth = terminalWidth
        self.showHeader = showHeader
    }
}
