import AppKit
import ForgeLoopGit

/// Renders parsed diffs into a colored attributed string for the panel's
/// read-only diff view. Pure view code; parsing lives in ForgeLoopGit.
enum DiffRenderer {
    static func attributedString(for files: [FileDiff]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)

        for (fileIndex, file) in files.enumerated() {
            if fileIndex > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            result.append(NSAttributedString(string: file.path + "\n", attributes: [
                .font: boldFont,
                .foregroundColor: NSColor.labelColor
            ]))
            for hunk in file.hunks {
                var header = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
                if let heading = hunk.heading {
                    header += " \(heading)"
                }
                result.append(NSAttributedString(string: header + "\n", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.systemBlue
                ]))
                for line in hunk.lines {
                    result.append(attributedLine(line, font: font))
                }
            }
        }
        return result
    }

    /// One diff line: the `+`/`-`/space marker re-attached, colored by kind, with
    /// intraline emphasis ranges tinted with a stronger background.
    private static func attributedLine(_ line: DiffLine, font: NSFont) -> NSAttributedString {
        let marker: String
        let color: NSColor
        switch line.kind {
        case .addition:
            marker = "+"
            color = .systemGreen
        case .deletion:
            marker = "-"
            color = .systemRed
        case .context:
            marker = " "
            color = .labelColor
        }
        let attributed = NSMutableAttributedString(string: marker + line.text + "\n", attributes: [
            .font: font,
            .foregroundColor: color
        ])
        for span in line.emphasis where span.upperBound <= line.text.count {
            let start = line.text.index(line.text.startIndex, offsetBy: span.lowerBound)
            let end = line.text.index(line.text.startIndex, offsetBy: span.upperBound)
            let range = NSRange(start..<end, in: line.text)
            // +1 for the re-attached marker.
            attributed.addAttribute(
                .backgroundColor,
                value: color.withAlphaComponent(0.25),
                range: NSRange(location: range.location + 1, length: range.length)
            )
        }
        return attributed
    }
}
