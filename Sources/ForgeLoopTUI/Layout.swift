import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct TerminalSize: Sendable, Equatable {
    public let rows: Int
    public let columns: Int
}

public func getTerminalSize() -> TerminalSize? {
    var ws = winsize()
    guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0 else { return nil }
    return TerminalSize(rows: Int(ws.ws_row), columns: Int(ws.ws_col))
}

public struct Layout: Sendable {
    public var header: [String] = []
    public var transcript: [String] = []
    public var queue: [String] = []
    public var status: [String] = []
    public var input: [String] = []

    public init() {}
}

public struct LayoutConfig: Sendable {
    public let terminalHeight: Int
    public let terminalWidth: Int
    public let showHeader: Bool

    public init(terminalHeight: Int = 24, terminalWidth: Int = 80, showHeader: Bool = true) {
        self.terminalHeight = terminalHeight
        self.terminalWidth = terminalWidth
        self.showHeader = showHeader
    }
}

// MARK: - ANSI / Physical Row Helpers

/// Strip ANSI escape sequences from a string, returning plain visible text.
public func ansiStripped(_ text: String) -> String {
    var result = ""
    var index = text.startIndex
    while index < text.endIndex {
        let char = text[index]
        if char == "\u{1B}" {
            // Skip ESC and following CSI parameters + final byte
            let next = text.index(after: index)
            if next < text.endIndex, text[next] == "[" {
                var paramIndex = text.index(after: next)
                while paramIndex < text.endIndex {
                    let paramChar = text[paramIndex]
                    if (0x40...0x7E).contains(paramChar.asciiValue ?? 0) {
                        index = text.index(after: paramIndex)
                        break
                    }
                    paramIndex = text.index(after: paramIndex)
                }
                if paramIndex >= text.endIndex {
                    break
                }
                continue
            }
        }
        result.append(char)
        index = text.index(after: index)
    }
    return result
}

/// Calculate visible display width of a string (CJK/wide chars = 2, ANSI = 0).
public func visibleWidth(_ text: String) -> Int {
    let stripped = ansiStripped(text)
    var width = 0
    for scalar in stripped.unicodeScalars {
        let value = scalar.value
        if value < 0x20 || value == 0x7F {
            // Control chars: width 0
            continue
        }
        if value < 0x7F {
            width += 1
            continue
        }
        // East Asian Wide / Fullwidth ranges
        let isWide = (0x1100...0x115F).contains(value)
            || (0x231A...0x231B).contains(value)
            || (0x2329...0x232A).contains(value)
            || (0x23E9...0x23EC).contains(value)
            || (0x23F0...0x23F0).contains(value)
            || (0x23F3...0x23F3).contains(value)
            || (0x25FD...0x25FE).contains(value)
            || (0x2614...0x2615).contains(value)
            || (0x2648...0x2653).contains(value)
            || (0x267F...0x267F).contains(value)
            || (0x2693...0x2693).contains(value)
            || (0x26A1...0x26A1).contains(value)
            || (0x26AA...0x26AB).contains(value)
            || (0x26BD...0x26BE).contains(value)
            || (0x26C4...0x26C5).contains(value)
            || (0x26CE...0x26CE).contains(value)
            || (0x26D4...0x26D4).contains(value)
            || (0x26EA...0x26EA).contains(value)
            || (0x26F2...0x26F3).contains(value)
            || (0x26F5...0x26F5).contains(value)
            || (0x26FA...0x26FA).contains(value)
            || (0x26FD...0x26FD).contains(value)
            || (0x2705...0x2705).contains(value)
            || (0x270A...0x270B).contains(value)
            || (0x2728...0x2728).contains(value)
            || (0x274C...0x274C).contains(value)
            || (0x274E...0x274E).contains(value)
            || (0x2753...0x2755).contains(value)
            || (0x2795...0x2797).contains(value)
            || (0x27B0...0x27B0).contains(value)
            || (0x27BF...0x27BF).contains(value)
            || (0x2B1B...0x2B1C).contains(value)
            || (0x2B50...0x2B50).contains(value)
            || (0x2B55...0x2B55).contains(value)
            || (0x2E80...0x303E).contains(value)
            || (0x3041...0x3096).contains(value)
            || (0x3099...0x30FF).contains(value)
            || (0x3105...0x312F).contains(value)
            || (0x3131...0x318E).contains(value)
            || (0x3190...0x31BA).contains(value)
            || (0x31C0...0x31E3).contains(value)
            || (0x31F0...0x321E).contains(value)
            || (0x3220...0x3247).contains(value)
            || (0x3250...0x32FE).contains(value)
            || (0x3300...0x4DBF).contains(value)
            || (0x4E00...0xA48C).contains(value)
            || (0xA490...0xA4C6).contains(value)
            || (0xA960...0xA97C).contains(value)
            || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE10...0xFE19).contains(value)
            || (0xFE30...0xFE52).contains(value)
            || (0xFE54...0xFE66).contains(value)
            || (0xFE68...0xFE6B).contains(value)
            || (0xFF01...0xFF60).contains(value)
            || (0xFFE0...0xFFE6).contains(value)
            || (0x1F100...0x1F10A).contains(value)
            || (0x1F110...0x1F12D).contains(value)
            || (0x1F130...0x1F169).contains(value)
            || (0x1F170...0x1F19A).contains(value)
            || (0x1F200...0x1F202).contains(value)
            || (0x1F210...0x1F23B).contains(value)
            || (0x1F240...0x1F248).contains(value)
            || (0x1F250...0x1F251).contains(value)
            || (0x1F260...0x1F265).contains(value)
            || (0x1F300...0x1F320).contains(value)
            || (0x1F32D...0x1F335).contains(value)
            || (0x1F337...0x1F37C).contains(value)
            || (0x1F37E...0x1F393).contains(value)
            || (0x1F3A0...0x1F3CA).contains(value)
            || (0x1F3CF...0x1F3D3).contains(value)
            || (0x1F3E0...0x1F3F0).contains(value)
            || (0x1F3F4...0x1F3F4).contains(value)
            || (0x1F3F8...0x1F43E).contains(value)
            || (0x1F440...0x1F440).contains(value)
            || (0x1F442...0x1F4FC).contains(value)
            || (0x1F4FF...0x1F53D).contains(value)
            || (0x1F54B...0x1F54E).contains(value)
            || (0x1F550...0x1F567).contains(value)
            || (0x1F57A...0x1F57A).contains(value)
            || (0x1F595...0x1F596).contains(value)
            || (0x1F5A4...0x1F5A4).contains(value)
            || (0x1F5FB...0x1F64F).contains(value)
            || (0x1F680...0x1F6C5).contains(value)
            || (0x1F6CC...0x1F6CC).contains(value)
            || (0x1F6D0...0x1F6D2).contains(value)
            || (0x1F6EB...0x1F6EC).contains(value)
            || (0x1F6F4...0x1F6F9).contains(value)
            || (0x1F910...0x1F93E).contains(value)
            || (0x1F940...0x1F970).contains(value)
            || (0x1F973...0x1F976).contains(value)
            || (0x1F97A...0x1F97A).contains(value)
            || (0x1F97C...0x1F9A2).contains(value)
            || (0x1F9B0...0x1F9B9).contains(value)
            || (0x1F9C0...0x1F9C2).contains(value)
            || (0x1F9D0...0x1F9FF).contains(value)
            || (0x20000...0x2FFFD).contains(value)
            || (0x30000...0x3FFFD).contains(value)
        if isWide {
            width += 2
        } else {
            width += 1
        }
    }
    return width
}

/// Calculate physical rows for a line given terminal width.
public func physicalRows(for line: String, width: Int) -> Int {
    guard width > 0 else { return 1 }
    let vw = visibleWidth(line)
    if vw == 0 { return 1 }
    return (vw + width - 1) / width
}
