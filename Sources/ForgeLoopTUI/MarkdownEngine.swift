import Foundation

public protocol MarkdownEngine: AnyObject {
    func reset()
    func render(text: String, isFinal: Bool) -> [String]
}

public final class PlainTextMarkdownEngine: MarkdownEngine {
    public init() {}

    public func reset() {}

    public func render(text: String, isFinal: Bool) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

/// 流式 Markdown 引擎（最小实现）：
/// - 维护单调递增 stable boundary（按完整行推进）；
/// - 仅重渲染 unstable tail；
/// - 对完整 GFM 表格块渲染为可读的 box table；
/// - 对未闭合表格在 streaming 阶段降级为纯文本。
public final class StreamingMarkdownEngine: MarkdownEngine {
    private var stableSource = ""
    private var stableRendered: [String] = []

    public init() {}

    public func reset() {
        stableSource = ""
        stableRendered = []
    }

    public func render(text: String, isFinal: Bool) -> [String] {
        guard !text.isEmpty else {
            reset()
            return []
        }

        if !stableSource.isEmpty, !text.hasPrefix(stableSource) {
            reset()
        }

        let suffix = String(text.dropFirst(stableSource.count))
        let advance = stableAdvance(in: suffix, isFinal: isFinal)
        if advance > 0 {
            let stableDelta = String(suffix.prefix(advance))
            stableSource += stableDelta
            var deltaRendered = renderFully(text: stableDelta, isFinal: true)
            let unstable = String(text.dropFirst(stableSource.count))
            if !unstable.isEmpty, stableDelta.hasSuffix("\n"), deltaRendered.last == "" {
                deltaRendered.removeLast()
            }
            stableRendered += deltaRendered
        }

        let unstable = String(text.dropFirst(stableSource.count))
        let unstableRendered = renderFully(text: unstable, isFinal: isFinal)
        return stableRendered + unstableRendered
    }

    private func stableAdvance(in text: String, isFinal: Bool) -> Int {
        guard !text.isEmpty else { return 0 }
        if isFinal { return text.count }
        guard let lastNewline = text.lastIndex(of: "\n") else { return 0 }
        let candidateEnd = text.index(after: lastNewline)
        let candidateText = String(text[..<candidateEnd])

        // 不要把“表头 + 分隔线”冻结为 stable 前缀；需等待至少一行数据。
        let lines = candidateText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count >= 3 {
            let trailingEmpty = lines.last == ""
            let dividerIndex = trailingEmpty ? lines.count - 2 : lines.count - 1
            let headerIndex = dividerIndex - 1
            if headerIndex >= 0,
                parseTableCells(lines[headerIndex]) != nil,
                parseDividerCells(lines[dividerIndex]) != nil
            {
                let prefixLines = lines.prefix(headerIndex)
                let prefixText = prefixLines.joined(separator: "\n")
                var retreat = prefixText.count
                if headerIndex > 0 {
                    retreat += 1 // newline before header line
                }
                return retreat
            }
        }

        return text.distance(from: text.startIndex, to: candidateEnd)
    }

    private func renderFully(text: String, isFinal: Bool) -> [String] {
        guard !text.isEmpty else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let endsWithNewline = text.hasSuffix("\n")

        var rendered: [String] = []
        var index = 0
        while index < lines.count {
            if let table = parseTable(lines: lines, start: index, isFinal: isFinal, endsWithNewline: endsWithNewline) {
                rendered.append(contentsOf: table.lines)
                index += table.consumed
                continue
            }
            rendered.append(lines[index])
            index += 1
        }
        return rendered
    }

    private func parseTable(
        lines: [String],
        start: Int,
        isFinal: Bool,
        endsWithNewline: Bool
    ) -> (lines: [String], consumed: Int)? {
        guard start + 1 < lines.count else { return nil }

        guard let headerCells = parseTableCells(lines[start]) else { return nil }
        guard let divider = parseDividerCells(lines[start + 1]), divider.count == headerCells.count else { return nil }

        var dataRows: [[String]] = []
        var cursor = start + 2
        while cursor < lines.count, let cells = parseTableCells(lines[cursor]) {
            dataRows.append(cells)
            cursor += 1
        }

        guard !dataRows.isEmpty else { return nil }

        // streaming 阶段：尾部未闭合时降级为纯文本，避免闪烁
        if !isFinal, cursor == lines.count, !endsWithNewline {
            return nil
        }

        let rendered = renderTable(header: headerCells, alignment: divider, rows: dataRows)
        return (rendered, cursor - start)
    }

    private enum CellAlign {
        case left
        case center
        case right
    }

    private func parseTableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), !trimmed.isEmpty else { return nil }

        var body = trimmed
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }

        let cells = body.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        return cells.count >= 2 ? cells : nil
    }

    private func parseDividerCells(_ line: String) -> [CellAlign]? {
        guard let cells = parseTableCells(line), !cells.isEmpty else { return nil }
        var aligns: [CellAlign] = []
        for cell in cells {
            let value = cell.trimmingCharacters(in: .whitespaces)
            let core = value.replacingOccurrences(of: ":", with: "")
            guard core.count >= 3, core.allSatisfy({ $0 == "-" }) else { return nil }

            if value.hasPrefix(":"), value.hasSuffix(":") {
                aligns.append(.center)
            } else if value.hasSuffix(":") {
                aligns.append(.right)
            } else {
                aligns.append(.left)
            }
        }
        return aligns
    }

    private func renderTable(header: [String], alignment: [CellAlign], rows: [[String]]) -> [String] {
        let normalizedRows = rows.map { normalize(cells: $0, count: header.count) }
        var widths = Array(repeating: 0, count: header.count)

        for col in 0..<header.count {
            widths[col] = max(widths[col], visibleWidth(header[col]))
            for row in normalizedRows {
                widths[col] = max(widths[col], visibleWidth(row[col]))
            }
            widths[col] = max(widths[col], 1)
        }

        var output: [String] = []
        output.append(borderLine(left: "┌", middle: "┬", right: "┐", widths: widths))
        output.append(tableRow(cells: header, aligns: alignment, widths: widths))
        output.append(borderLine(left: "├", middle: "┼", right: "┤", widths: widths))
        for row in normalizedRows {
            output.append(tableRow(cells: row, aligns: alignment, widths: widths))
        }
        output.append(borderLine(left: "└", middle: "┴", right: "┘", widths: widths))
        return output
    }

    private func normalize(cells: [String], count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    private func borderLine(left: String, middle: String, right: String, widths: [Int]) -> String {
        let segments = widths.map { String(repeating: "─", count: $0 + 2) }
        return left + segments.joined(separator: middle) + right
    }

    private func tableRow(cells: [String], aligns: [CellAlign], widths: [Int]) -> String {
        var parts: [String] = []
        for index in 0..<cells.count {
            parts.append(padded(cells[index], width: widths[index], align: aligns[index]))
        }
        return "│ " + parts.joined(separator: " │ ") + " │"
    }

    private func padded(_ value: String, width: Int, align: CellAlign) -> String {
        let textWidth = visibleWidth(value)
        let gap = max(0, width - textWidth)

        switch align {
        case .left:
            return value + String(repeating: " ", count: gap)
        case .right:
            return String(repeating: " ", count: gap) + value
        case .center:
            let left = gap / 2
            let right = gap - left
            return String(repeating: " ", count: left) + value + String(repeating: " ", count: right)
        }
    }
}
