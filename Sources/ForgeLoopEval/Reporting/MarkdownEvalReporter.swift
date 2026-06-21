import Foundation

/// Renders eval results as a human-readable Markdown report.
///
/// The report includes a summary table, a details table for all cases, and a
/// dedicated failures section when any case did not pass.
public struct MarkdownEvalReporter: EvalReporter {
    public init() {}

    public func report(results: [EvalResult]) async throws -> String {
        let report = EvalReport(results: results)
        var lines: [String] = []

        lines.append("# ForgeLoop Eval Report")
        lines.append("")
        lines.append("Generated at: \(report.generatedAt)")
        lines.append("")

        lines.append("## Summary")
        lines.append("")
        lines.append("| Total | Passed | Failed | Avg Score | Avg Duration |")
        lines.append("|------:|-------:|-------:|----------:|-------------:|")
        lines.append(
            "| \(report.summary.totalCases) " +
            "| \(report.summary.passedCases) " +
            "| \(report.summary.failedCases) " +
            "| \(formatScore(report.summary.averageScore)) " +
            "| \(formatDuration(report.summary.averageDurationMs)) |"
        )
        lines.append("")

        if report.results.isEmpty {
            lines.append("No cases were run.")
            lines.append("")
        } else {
            lines.append("## Details")
            lines.append("")
            lines.append("| Case ID | Passed | Score | Duration | Assertions |")
            lines.append("|---------|--------|------:|----------|-----------:|")
            for result in report.results {
                let assertionSummary = result.assertionResults.isEmpty
                    ? "—"
                    : "\(result.assertionResults.filter(\.passed).count)/\(result.assertionResults.count) passed"
                lines.append(
                    "| \(result.caseID) " +
                    "| \(result.passed ? "✅" : "❌") " +
                    "| \(formatScore(result.score)) " +
                    "| \(formatDuration(result.durationMs)) " +
                    "| \(assertionSummary) |"
                )
            }
            lines.append("")

            let failures = report.results.filter { !$0.passed }
            if !failures.isEmpty {
                lines.append("## Failures")
                lines.append("")
                for result in failures {
                    lines.append("### \(result.caseID)")
                    lines.append("")
                    lines.append("- **Score**: \(formatScore(result.score))")
                    lines.append("- **Duration**: \(formatDuration(result.durationMs))")
                    lines.append("")
                    lines.append("| Assertion | Passed | Message |")
                    lines.append("|-----------|--------|---------|")
                    for assertionResult in result.assertionResults {
                        lines.append(
                            "| \(assertionResult.assertion) " +
                            "| \(assertionResult.passed ? "✅" : "❌") " +
                            "| \(assertionResult.message) |"
                        )
                    }
                    lines.append("")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func formatScore(_ score: Double) -> String {
        String(format: "%.2f", score)
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        if milliseconds < 1000 {
            return "\(milliseconds)ms"
        }
        return String(format: "%.1fs", Double(milliseconds) / 1000.0)
    }
}
