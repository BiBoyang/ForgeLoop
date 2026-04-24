import Foundation

public func splitLogicalLines(_ text: String) -> [String] {
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    return normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

public func splitLogicalLines(_ lines: [String]) -> [String] {
    lines.flatMap(splitLogicalLines)
}

public func prefixedLogicalLines(prefix: String, text: String) -> [String] {
    let parts = splitLogicalLines(text)
    guard let first = parts.first else { return [prefix] }
    return [prefix + first] + parts.dropFirst()
}
