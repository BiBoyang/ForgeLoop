// Portions ported from termio (MIT): https://github.com/termio-sh/termio
// Original: Shared/Sources/TermioShared/DiffModel.swift
// Copyright (c) 2026 Jiwei Yuan
// https://github.com/termio-sh/termio/blob/main/LICENSE
import Foundation

/// One line of a parsed unified diff. `text` is the line *without* its
/// `+`/`-`/space marker, so a renderer can style the marker itself instead of
/// baking it in.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case addition, deletion, context }

    public let kind: Kind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
    /// The changed spans within a paired deletion/addition line, in `Character`
    /// offsets — rendered with a stronger tint so a one-word edit inside a long
    /// line reads at a glance. Empty when the line has no counterpart, or the two
    /// sides share too little for spans to mean anything.
    public var emphasis: [Range<Int>]

    public init(kind: Kind, text: String, oldLine: Int?, newLine: Int?, emphasis: [Range<Int>] = []) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
        self.emphasis = emphasis
    }
}

/// One `@@` section of a file's diff, with the section heading git appended
/// (the enclosing scope of the lines that follow) when there is one.
public struct DiffHunk: Equatable, Sendable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let heading: String?
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                heading: String?, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.heading = heading
        self.lines = lines
    }
}

/// One file's portion of a unified diff. `oldPath`/`newPath` are repo-relative;
/// a `nil` old path marks a new file, a `nil` new path a deletion.
public struct FileDiff: Equatable, Sendable {
    public let oldPath: String?
    public let newPath: String?
    public var hunks: [DiffHunk]

    public init(oldPath: String?, newPath: String?, hunks: [DiffHunk]) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
    }

    /// The path a UI row should be labeled with.
    public var path: String { newPath ?? oldPath ?? "" }
}

/// A parsed `@@` hunk header: both line ranges plus the optional section heading.
struct HunkHeader: Equatable, Sendable {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var heading: String?
}

/// Parses unified-diff text into a structured model, kept free of any UI
/// framework so any layer can render the result.
public enum DiffParser {
    /// Parses unified-diff text into per-file hunks, tracking old/new line
    /// numbers from each hunk header and dropping the plumbing lines (`index`,
    /// mode changes, …) that carry no code.
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var oldPath: String?
        var newPath: String?
        var hunks: [DiffHunk] = []
        var hunkLines: [DiffLine] = []
        var hunkHeader: HunkHeader?
        var inFile = false
        var oldLine = 0
        var newLine = 0

        func closeHunk() {
            guard let header = hunkHeader else { return }
            applyIntraline(&hunkLines)
            hunks.append(DiffHunk(oldStart: header.oldStart, oldCount: header.oldCount,
                                  newStart: header.newStart, newCount: header.newCount,
                                  heading: header.heading, lines: hunkLines))
            hunkLines = []
            hunkHeader = nil
        }

        func closeFile() {
            closeHunk()
            guard inFile else { return }
            files.append(FileDiff(oldPath: oldPath, newPath: newPath, hunks: hunks))
            oldPath = nil
            newPath = nil
            hunks = []
            inFile = false
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                closeFile()
                inFile = true
                continue
            }
            guard inFile else { continue }
            if line.hasPrefix("@@") {
                closeHunk()
                guard let header = parseHunkHeader(line) else { continue }
                hunkHeader = header
                oldLine = header.oldStart
                newLine = header.newStart
                continue
            }
            if line.hasPrefix("--- ") {
                oldPath = parseHeaderPath(String(line.dropFirst(4)))
                continue
            }
            if line.hasPrefix("+++ ") {
                newPath = parseHeaderPath(String(line.dropFirst(4)))
                continue
            }
            // Anything else before the first hunk is file-header plumbing.
            guard hunkHeader != nil, let marker = line.first else { continue }
            let body = String(line.dropFirst())
            switch marker {
            case "+":
                hunkLines.append(DiffLine(kind: .addition, text: body, oldLine: nil, newLine: newLine))
                newLine += 1
            case "-":
                hunkLines.append(DiffLine(kind: .deletion, text: body, oldLine: oldLine, newLine: nil))
                oldLine += 1
            case " ":
                hunkLines.append(DiffLine(kind: .context, text: body, oldLine: oldLine, newLine: newLine))
                oldLine += 1
                newLine += 1
            default:
                continue // "\ No newline at end of file" and friends
            }
        }
        closeFile()
        return files
    }

    // MARK: - Line scanning

    /// A `---`/`+++` header path: `/dev/null` becomes `nil` (new/deleted file),
    /// everything else loses its `a/`/`b/` prefix. Quoted paths (non-ASCII or
    /// control bytes, which git C-quotes) are not unescaped here.
    static func parseHeaderPath(_ raw: String) -> String? {
        if raw == "/dev/null" { return nil }
        if raw.hasPrefix("a/") || raw.hasPrefix("b/") { return String(raw.dropFirst(2)) }
        return raw
    }

    /// Pulls the ranges and section heading out of `@@ -a,b +c,d @@ func foo() {`.
    static func parseHunkHeader(_ line: String) -> HunkHeader? {
        let parts = line.components(separatedBy: "@@")
        guard parts.count >= 3 else { return nil }
        let heading = parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces)
        var oldRange: (Int, Int)?
        var newRange: (Int, Int)?
        for token in parts[1].split(separator: " ") {
            if token.hasPrefix("-") {
                oldRange = parseRange(String(token.dropFirst()))
            } else if token.hasPrefix("+") {
                newRange = parseRange(String(token.dropFirst()))
            }
        }
        guard let oldRange, let newRange else { return nil }
        return HunkHeader(oldStart: oldRange.0, oldCount: oldRange.1,
                          newStart: newRange.0, newCount: newRange.1,
                          heading: heading.isEmpty ? nil : heading)
    }

    /// `1,3` → (1, 3); a bare `1` (single-line range) → (1, 1).
    private static func parseRange(_ raw: String) -> (Int, Int)? {
        let pair = raw.split(separator: ",")
        guard let start = Int(pair.first ?? "") else { return nil }
        let count = pair.count > 1 ? Int(pair[1]) : 1
        guard let count else { return nil }
        return (start, count)
    }

    /// Marks the changed spans inside modified lines: within each hunk, a block of
    /// deletions immediately followed by a block of additions is paired index-wise,
    /// and each pair is word-diffed by `DiffIntraline`.
    private static func applyIntraline(_ lines: inout [DiffLine]) {
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .deletion else { index += 1; continue }
            let deletionStart = index
            while index < lines.count, lines[index].kind == .deletion { index += 1 }
            let additionStart = index
            while index < lines.count, lines[index].kind == .addition { index += 1 }
            for offset in 0..<min(additionStart - deletionStart, index - additionStart) {
                guard let spans = DiffIntraline.spans(old: lines[deletionStart + offset].text,
                                                      new: lines[additionStart + offset].text)
                else { continue }
                lines[deletionStart + offset].emphasis = spans.old
                lines[additionStart + offset].emphasis = spans.new
            }
        }
    }
}
