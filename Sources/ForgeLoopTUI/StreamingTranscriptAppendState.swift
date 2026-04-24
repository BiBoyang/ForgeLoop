import Foundation

public struct StreamingTranscriptAppendState: Sendable {
    public private(set) var printedTranscriptCount = 0
    public private(set) var printedCompletedStreamingLines: [String] = []

    public init() {}

    public mutating func consume(transcript: [String], activeRange: Range<Int>?) -> [String] {
        let clampedPrintedCount = min(printedTranscriptCount, transcript.count)
        if clampedPrintedCount != printedTranscriptCount {
            printedTranscriptCount = clampedPrintedCount
            printedCompletedStreamingLines = []
        }

        if let activeRange {
            let stableUpperBound = min(activeRange.lowerBound, transcript.count)
            var newLines: [String] = []

            if stableUpperBound > printedTranscriptCount {
                newLines.append(contentsOf: transcript[printedTranscriptCount..<stableUpperBound])
                printedTranscriptCount = stableUpperBound
            }

            let activeLines = Array(transcript[activeRange])
            let completedLines = activeLines.isEmpty ? [] : Array(activeLines.dropLast())
            let commonPrefixCount = zip(printedCompletedStreamingLines, completedLines)
                .prefix { $0 == $1 }
                .count

            if completedLines.count > commonPrefixCount {
                let appendedCompletedLines = Array(completedLines.dropFirst(commonPrefixCount))
                newLines.append(contentsOf: appendedCompletedLines)
                printedTranscriptCount += appendedCompletedLines.count
            }

            printedCompletedStreamingLines = completedLines
            return newLines
        }

        printedCompletedStreamingLines = []
        guard transcript.count > printedTranscriptCount else { return [] }
        let newLines = Array(transcript[printedTranscriptCount..<transcript.count])
        printedTranscriptCount = transcript.count
        return newLines
    }
}
